#!/bin/sh
# claude-tmux-service — keep a Claude Code Remote Control session alive in tmux.
#
# Runs as a watchdog: every $CLAUDE_TMUX_INTERVAL seconds it checks whether
# the tmux session exists; if claude exited (network timeout, crash, /exit),
# the session dies and this loop recreates it. When the network comes back,
# the session reconnects within one interval.
#
# Creating the session is not enough on its own. If claude starts before the
# network is up it fails to register with Remote Control but does NOT exit —
# it keeps running as an ordinary local session. The session then exists, a
# naive watchdog is satisfied, and the machine never appears in the Claude
# app. So every spawn is verified: the pane must show the "remote-control is
# active" banner, and the session is recycled if it never does.
#
# Usage:
#   claude-remote-start.sh          run the watchdog loop (used by the service)
#   claude-remote-start.sh start    create the session once, verified, and exit
#   claude-remote-start.sh stop     kill the tmux session
#   claude-remote-start.sh status   report whether the session is registered
#   claude-remote-start.sh login    sign in to claude.ai: prints the URL and
#                                   relays the code you paste back
#
# Configuration (environment or ~/.config/claude-tmux/env):
#   CLAUDE_TMUX_SESSION      tmux session name         (default: short hostname)
#   CLAUDE_TMUX_ARGS         extra args for claude     (default: --dangerously-skip-permissions)
#   CLAUDE_TMUX_INTERVAL     watchdog check interval   (default: 30 seconds)
#   CLAUDE_TMUX_VERIFY       spawn verification budget (default: 60 seconds, 0 disables)
#   CLAUDE_TMUX_NET_WAIT     network wait budget       (default: 55 seconds, 0 disables)
#   CLAUDE_TMUX_READY        banner meaning "registered"
#                            (default: remote-control is active)
#   CLAUDE_TMUX_AUTO_TRUST   answer claude's first-run gates (default: 1)
#   CLAUDE_TMUX_MAX_BACKOFF  cap on the retry delay    (default: 300 seconds)
#   CLAUDE_TMUX_LOGIN_WAIT   budget for the `login` walkthrough (default: 600s)
set -u

# Cover the common install locations across distros and macOS:
# ~/.local/bin (native installer), linuxbrew, homebrew (ARM + Intel mac), npm -g.
PATH="$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claude-tmux/env"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"

SESSION="${CLAUDE_TMUX_SESSION:-$(hostname -s)}"
ARGS="${CLAUDE_TMUX_ARGS---dangerously-skip-permissions}"
INTERVAL="${CLAUDE_TMUX_INTERVAL:-30}"
VERIFY="${CLAUDE_TMUX_VERIFY:-60}"
NET_WAIT="${CLAUDE_TMUX_NET_WAIT:-55}"
READY="${CLAUDE_TMUX_READY:-remote-control is active}"
AUTO_TRUST="${CLAUDE_TMUX_AUTO_TRUST:-1}"
MAX_BACKOFF="${CLAUDE_TMUX_MAX_BACKOFF:-300}"
NOTIFY="${CLAUDE_TMUX_NOTIFY:-1}"

# How often to re-read the pane while verifying a fresh spawn.
VERIFY_STEP=5

# A logout is the one failure the watchdog cannot fix on its own: restoring it
# needs an interactive claude.ai login that an unattended service can't perform.
# So when it's detected we leave a marker here — read back by `status` — and
# raise a desktop notification, turning a silently dead service into one that
# says why it stopped and how to revive it.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-tmux"
LOGOUT_MARK="$STATE_DIR/logged-out"

# A stuck setup — logged out, no network, a renamed banner — fails identically
# on every retry, and each retry emits the same handful of lines. Left alone
# that floods the log with hundreds of copies of one situation. So within a
# failure streak each distinct message is written once; repeats are dropped
# until the streak ends. The run loop calls log_reset once a spawn succeeds, so
# a situation that recurs later still gets logged afresh.
LOG_SEEN=""
LOG_NOTED_SUPPRESS=0

log() {
  _msg="claude-tmux: $*"
  # Quoting $_msg in the pattern matches it literally — no globbing. The
  # leading newline anchors each entry so one message can't match inside
  # another; every stored line therefore starts with a newline too.
  case "$LOG_SEEN" in
    *"
$_msg"*)
      if [ "$LOG_NOTED_SUPPRESS" -eq 0 ]; then
        echo "claude-tmux: (repeating messages suppressed until the situation changes)" >&2
        LOG_NOTED_SUPPRESS=1
      fi
      return ;;
  esac
  LOG_SEEN="$LOG_SEEN
$_msg"
  echo "$_msg" >&2
}

# Forget the current streak's messages so the next failure logs from scratch.
log_reset() {
  LOG_SEEN=""
  LOG_NOTED_SUPPRESS=0
  NOTIFIED=0
}

# Best-effort desktop notification, so a logout — which the watchdog cannot fix
# on its own — reaches the person instead of only landing in the log. Tries the
# common notifiers in turn and stays silent where none exists; never fails the
# caller. Messages must stay free of double quotes for the osascript form.
notify() {
  [ "$NOTIFY" = 0 ] && return 0
  _title="Claude Remote Control"
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "$_title" -message "$1" >/dev/null 2>&1
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$1\" with title \"$_title\"" >/dev/null 2>&1
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$_title" "$1" >/dev/null 2>&1
  fi
  return 0
}

# Notify at most once per failure streak; log_reset clears the guard, so a
# logout that recurs after a recovery notifies again rather than staying quiet.
NOTIFIED=0
notify_once() {
  [ "$NOTIFIED" -eq 0 ] || return 0
  NOTIFIED=1
  notify "$1"
}

# Record / clear the "logged out" state that `status` reports. Both are
# best-effort: a service that can't write its state dir should still run.
mark_logged_out() {
  mkdir -p "$STATE_DIR" 2>/dev/null && : > "$LOGOUT_MARK" 2>/dev/null
  return 0
}
clear_logged_out() {
  rm -f "$LOGOUT_MARK" 2>/dev/null
  return 0
}

die() {
  log "$*"
  exit 1
}

command -v tmux >/dev/null 2>&1 || die "tmux not found in PATH"

pane_text() {
  tmux capture-pane -t "$SESSION" -p -S - 2>/dev/null
}

# How much of the pane's opening output counts as "startup", for pane_head.
HEAD_LINES=100

pane_prop() {
  tmux display-message -p -t "$SESSION" "$1" 2>/dev/null
}

# The banner is printed once, at startup, so it sits at the very top of the
# pane's history. Read only that opening stretch. Scanning the whole scrollback
# instead also matches the phrase turning up in the session's *own* output —
# and since this session is itself a claude that can be asked about its own
# banner, a full-scrollback check reports "registered" no matter what is true.
pane_head() {
  size=$(pane_prop '#{history_size}')
  case "${size:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$size" -le "$HEAD_LINES" ]; then
    pane_text
  else
    tmux capture-pane -t "$SESSION" -p -S "-$size" -E "$((HEAD_LINES - size))" 2>/dev/null
  fi
}

# Once the history is full tmux drops its oldest lines, taking the startup
# banner with them — absence stops being evidence at that point.
history_trimmed() {
  size=$(pane_prop '#{history_size}')
  limit=$(pane_prop '#{history_limit}')
  case "${size:-}${limit:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$size" -ge "$limit" ]
}

# Just the visible screen, no scrollback. What is on screen *now* is the only
# way to tell whether a keypress advanced past a gate: the scrollback keeps
# showing the gate either way.
pane_screen() {
  tmux capture-pane -t "$SESSION" -p 2>/dev/null
}

contains() {
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  return 1
}

# A systemd *user* unit cannot order itself after the network:
# network-online.target does not exist in the user manager, so the unit's
# After=/Wants= lines are silently no-ops. Asking NetworkManager over D-Bus is
# the reliable wait, and needs no HTTP probe. Where nm-online is unavailable
# (macOS, non-NetworkManager systems) the verification step below is what
# catches a too-early start.
network_ready() {
  [ "$NET_WAIT" -gt 0 ] || return 0
  command -v nm-online >/dev/null 2>&1 || return 0
  nm-online -q -t "$NET_WAIT"
}

# Answer one of claude's first-run gates by picking menu entry $1. $2 names the
# gate in the log. Returns 1, session already killed, when auto-answering is
# switched off, so the caller can fail the spawn with the reason on record.
answer_gate() {
  if [ "$AUTO_TRUST" = 0 ]; then
    log "claude is waiting on the $2 for $HOME."
    log "Answer it once by hand, or drop CLAUDE_TMUX_AUTO_TRUST=0 to let the"
    log "watchdog answer it. claude saves the answer either way."
    tmux kill-session -t "$SESSION" 2>/dev/null
    return 1
  fi
  log "answering the $2 for $HOME"
  # Pick by number rather than by position: the two menus disagree about which
  # entry comes first, and Bypass Permissions leads with "No, exit".
  tmux send-keys -t "$SESSION" "$1"
  sleep 2

  # Then confirm — but only if the gate is still up. Some of these menus act on
  # the digit alone and advance immediately, whatever their "Enter to confirm"
  # footer says. An unconditional Enter therefore lands on whichever screen came
  # next, and the screen after the trust prompt is the Bypass warning, which
  # defaults to "No, exit": the stray Enter quits claude a few seconds after
  # starting it. Matching on the visible screen, not the scrollback, is what
  # makes "did it advance?" answerable at all — the scrollback shows the gate
  # either way. $3 is the text that identified this gate.
  if contains "$(pane_screen)" "$3"; then
    tmux send-keys -t "$SESSION" Enter
  fi
}

# Confirm that a freshly spawned session actually registered with Remote
# Control. Returns 0 once the banner appears; otherwise kills the session so
# the next watchdog pass starts from a clean slate.
verify_session() {
  [ "$VERIFY" -gt 0 ] || return 0

  waited=0
  theme_answered=0
  trust_answered=0
  bypass_answered=0
  while [ "$waited" -lt "$VERIFY" ]; do
    sleep "$VERIFY_STEP"
    waited=$((waited + VERIFY_STEP))

    # claude exiting this fast is almost always a login problem: Remote
    # Control refuses to start without a claude.ai subscription session.
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      log "claude exited ${waited}s after starting."
      log "If this repeats, run 'claude' and check /login — Remote Control needs"
      log "a claude.ai Pro/Max login, not an API key."
      return 1
    fi

    out=$(pane_text)
    if contains "$out" "$READY"; then
      clear_logged_out
      return 0
    fi

    if contains "$out" "must be logged in" || contains "$out" "Not logged in"; then
      log "claude reports it is not logged in; Remote Control cannot start."
      log "Run '$0 login' to sign in — it drives 'claude auth login' for you,"
      log "prints the URL, and takes the code you paste back."
      mark_logged_out
      notify_once "Logged out of claude.ai — run 'claude auth login' to restore Remote Control."
      tmux kill-session -t "$SESSION" 2>/dev/null
      return 1
    fi

    # Setup's sign-in step is the one gate no watchdog can answer: it wants a
    # URL opened in a browser and a code pasted back. Say so and stop, rather
    # than burning the verification budget in front of a screen that will never
    # advance on its own.
    if contains "$out" "Select login method" || contains "$out" "Paste code here"; then
      log "claude is waiting on its sign-in screen; this needs a person."
      log "Run '$0 login' — it walks the first-run setup, prints the URL, and"
      log "relays the code you paste back."
      mark_logged_out
      notify_once "Claude Code needs an interactive sign-in — run claude-remote-start.sh login"
      tmux kill-session -t "$SESSION" 2>/dev/null
      return 1
    fi

    # A machine's first launch hits one-time gates that block until answered,
    # and an unattended session has nobody to answer them: the theme picker,
    # the workspace trust prompt, then — because the default ARGS pass
    # --dangerously-skip-permissions — the Bypass Permissions warning. claude
    # saves every answer, so each fires once per machine. Answering grants
    # nothing those defaults do not already grant; CLAUDE_TMUX_AUTO_TRUST=0
    # opts out and fails the spawn with the reason logged instead.
    #
    # Answer each at most once per spawn: capture-pane reads the scrollback
    # too, so a dismissed prompt stays matchable and an unguarded match would
    # keep typing stray digits into the running session.

    # A brand-new install opens on the theme picker, before anything else.
    # Nothing downstream reads the theme and nobody watches this pane, so take
    # "Auto (match terminal)" and leave the terminal's own colours alone.
    if [ "$theme_answered" -eq 0 ] && contains "$out" "Choose the text style"; then
      answer_gate 1 "theme picker" "Choose the text style" || return 1
      theme_answered=1
      continue
    fi

    if [ "$trust_answered" -eq 0 ] && contains "$out" "trust this folder"; then
      answer_gate 1 "workspace trust prompt" "trust this folder" || return 1
      trust_answered=1
      continue
    fi

    if [ "$bypass_answered" -eq 0 ] && contains "$out" "Bypass Permissions mode"; then
      answer_gate 2 "Bypass Permissions warning" "Bypass Permissions mode" || return 1
      bypass_answered=1
      continue
    fi
  done

  log "session '$SESSION' started but never showed '$READY' within ${VERIFY}s;"
  log "recycling it. If Claude Code renamed that banner, set CLAUDE_TMUX_READY."
  tmux kill-session -t "$SESSION" 2>/dev/null
  return 1
}

ensure_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    return 0
  fi
  if ! command -v claude >/dev/null 2>&1; then
    log "claude not found in PATH, will retry"
    return 1
  fi
  if ! network_ready; then
    log "network not ready after ${NET_WAIT}s, will retry"
    return 1
  fi

  # shellcheck disable=SC2086 — ARGS is intentionally word-split
  tmux new-session -d -s "$SESSION" -c "$HOME" \
    claude --remote-control "$SESSION" $ARGS || {
      log "tmux new-session failed, will retry"
      return 1
    }

  verify_session
}

# Retry delay: $INTERVAL normally, doubling while the session keeps failing to
# come up, capped at $MAX_BACKOFF. A permanently broken setup (logged out, no
# network, renamed banner) then costs one attempt every few minutes instead of
# spinning at full rate forever.
retry_delay() {
  delay="$INTERVAL"
  n=1
  while [ "$n" -lt "$1" ] && [ "$delay" -lt "$MAX_BACKOFF" ]; do
    delay=$((delay * 2))
    n=$((n + 1))
  done
  [ "$delay" -gt "$MAX_BACKOFF" ] && delay="$MAX_BACKOFF"
  echo "$delay"
}

# --- interactive first-run / login -----------------------------------------
# One step of a first run cannot be automated, by design: signing in needs a
# person to open a URL in a browser and paste back the code. Everything around
# it can be, and doing it by hand on a headless box is tedious — the URL
# arrives split across three lines of a tmux pane, and the menus before and
# after it have to be answered blind.
#
# So `login` drives the whole first run and asks for exactly the one thing only
# a person can supply. It walks the menus, stops at the sign-in screen to print
# the URL and read the code, and hands back to the watchdog once claude has
# recorded the run as complete.
#
# It drives the real TUI rather than `claude auth login`, because onboarding
# insists on its own sign-in step: a token stored by the CLI subcommand leaves
# `claude auth status` reporting a healthy Pro login while the TUI still opens
# on its sign-in screen and asks for a fresh code.
#
# Finishing matters as much as starting. Onboarding is only written down —
# hasCompletedOnboarding in ~/.claude.json — once the run reaches the end, so a
# session killed at the sign-in screen leaves the machine to start over from
# the theme picker forever. That flag, not a guess about which screen is up, is
# what this waits for.

LOGIN_SESSION="${SESSION}-login"
LOGIN_BUDGET="${CLAUDE_TMUX_LOGIN_WAIT:-600}"
ONBOARD_STATE="$HOME/.claude.json"

login_pane() {
  tmux capture-pane -t "$LOGIN_SESSION" -p -J -S - 2>/dev/null
}

# Only the visible screen — see pane_screen. Gates are matched here, so a
# dismissed menu sitting in the scrollback cannot be answered twice.
login_screen() {
  tmux capture-pane -t "$LOGIN_SESSION" -p 2>/dev/null
}

# Rebuild the sign-in URL from the pane.
#
# capture-pane -J rejoins what *tmux* wrapped, which is enough for ordinary
# stdout — but the TUI draws the URL itself, emitting each screenful as its own
# rendered line, and those carry no wrap flag for -J to act on. Handing over
# only the first of them sends the person to a truncated URL that fails at
# claude.com with no hint as to why. So: start at the https:// line and glue on
# the lines that follow while they still look like URL (a single run of
# non-blank characters). claude's own prose is indented and spaced, so the
# first line with a space in it ends the URL.
login_url() {
  login_pane | awk '
    /^https:\/\/[^ 	]*oauth/ { url = $0; more = 1; next }
    more && /^[^ 	]+$/       { url = url $0; next }
    more                      { more = 0 }
    END { if (url != "") print url }
  '
}

# Pick menu entry $1, named $2, identified on screen by $3. Same shape as
# answer_gate, including why the Enter is conditional: these menus act on the
# digit alone, and an Enter that arrives after the screen has moved on lands on
# the next one — where it would answer the Bypass warning's "No, exit".
login_pick() {
  echo "  answering the $2" >&2
  tmux send-keys -t "$LOGIN_SESSION" "$1"
  sleep 2
  if contains "$(login_screen)" "$3"; then
    tmux send-keys -t "$LOGIN_SESSION" Enter
  fi
}

onboarding_done() {
  [ -f "$ONBOARD_STATE" ] || return 1
  grep -q '"hasCompletedOnboarding"[[:space:]]*:[[:space:]]*true' "$ONBOARD_STATE"
}

login_cleanup() {
  tmux kill-session -t "$LOGIN_SESSION" 2>/dev/null
  return 0
}

do_login() {
  command -v claude >/dev/null 2>&1 || die "claude not found in PATH"

  login_cleanup
  # A wide pane leaves the URL with fewer wrap points to be rebuilt from. No
  # --remote-control: this session is here to answer setup, and registering it
  # would collide with the one the watchdog owns.
  # shellcheck disable=SC2086 — ARGS is intentionally word-split
  tmux new-session -d -s "$LOGIN_SESSION" -x 200 -y 50 -c "$HOME" \
    claude $ARGS || die "could not start the login session"

  echo "Walking Claude Code's first-run setup..." >&2

  code_sent=0
  waited=0

  while [ "$waited" -lt "$LOGIN_BUDGET" ]; do
    if onboarding_done; then
      echo "Setup complete." >&2
      login_cleanup
      clear_logged_out
      # The watchdog backs off hard on a machine it cannot fix, so left alone
      # it would idle for minutes after the login is repaired. Dropping the
      # stale session makes the next pass rebuild it immediately.
      tmux kill-session -t "$SESSION" 2>/dev/null
      echo "The watchdog will rebuild the session within ${INTERVAL}s." >&2
      echo "Check it with: $0 status" >&2
      return 0
    fi

    if ! tmux has-session -t "$LOGIN_SESSION" 2>/dev/null; then
      echo "The setup session exited before finishing." >&2
      [ "$code_sent" -eq 1 ] &&
        echo "The code may have been rejected — run this again for a fresh URL." >&2
      return 1
    fi

    screen=$(login_screen)

    if contains "$screen" "Choose the text style"; then
      login_pick 1 "theme picker" "Choose the text style"
      sleep 3
      continue
    fi

    if contains "$screen" "Select login method"; then
      login_pick 1 "login method (Claude subscription)" "Select login method"
      sleep 5
      continue
    fi

    # The one human step. Everything else here exists to reach it cleanly.
    if [ "$code_sent" -eq 0 ] && contains "$screen" "Paste code here"; then
      url=$(login_url)
      if [ -z "$url" ]; then
        sleep 3
        waited=$((waited + 3))
        continue
      fi
      echo >&2
      echo "Open this URL, sign in with your claude.ai Pro/Max account," >&2
      echo "then paste the code it gives you back here:" >&2
      echo >&2
      echo "$url" >&2
      echo >&2
      printf 'Code: ' >&2
      read -r code || code=""
      [ -n "$code" ] || { login_cleanup; die "no code entered; login abandoned"; }

      # -l sends it literally: the code carries a '#', which tmux would
      # otherwise read as the start of a format string.
      tmux send-keys -t "$LOGIN_SESSION" -l "$code"
      sleep 1
      tmux send-keys -t "$LOGIN_SESSION" Enter
      code_sent=1
      echo "  code sent, waiting for claude to accept it" >&2
      sleep 8
      continue
    fi

    # Two screens in the run are pure acknowledgements — "Login successful" and
    # the security notes — and both wait on Enter with nothing to choose.
    if contains "$screen" "Press Enter to continue"; then
      echo "  acknowledging a notice" >&2
      tmux send-keys -t "$LOGIN_SESSION" Enter
      sleep 3
      continue
    fi

    if contains "$screen" "trust this folder"; then
      login_pick 1 "workspace trust prompt" "trust this folder"
      sleep 3
      continue
    fi

    if contains "$screen" "Bypass Permissions mode"; then
      login_pick 2 "Bypass Permissions warning" "Bypass Permissions mode"
      sleep 3
      continue
    fi

    sleep 3
    waited=$((waited + 3))
  done

  login_cleanup
  echo "Setup did not finish within ${LOGIN_BUDGET}s." >&2
  return 1
}
case "${1:-run}" in
  run)
    failures=0
    while :; do
      if ensure_session; then
        failures=0
        log_reset
        sleep "$INTERVAL"
      else
        [ "$failures" -lt 32 ] && failures=$((failures + 1))
        sleep "$(retry_delay "$failures")"
      fi
    done
    ;;
  start)
    ensure_session
    ;;
  stop)
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    ;;
  login)
    do_login
    ;;
  status)
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      if [ -f "$LOGOUT_MARK" ]; then
        echo "session '$SESSION': not running — logged out of claude.ai."
        echo "Run '$0 login' with your Pro/Max account to restore it; it drives"
        echo "'claude auth login' and relays the code for you."
        exit 1
      fi
      echo "session '$SESSION': not running"
      exit 1
    fi
    if contains "$(pane_head)" "$READY"; then
      clear_logged_out
      echo "session '$SESSION': running, registered with Remote Control"
    elif history_trimmed; then
      # Exit 2, not 0 or 1: nothing is known to be wrong, but nothing is
      # confirmed either, and a caller should be able to tell those apart.
      echo "session '$SESSION': running; registration unconfirmed — the startup"
      echo "output has scrolled out of the tmux history. Check the Claude app."
      exit 2
    else
      echo "session '$SESSION': running but NOT registered with Remote Control"
      exit 1
    fi
    ;;
  *)
    die "unknown command: $1 (expected run, start, stop, status or login)"
    ;;
esac
