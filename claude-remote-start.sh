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

# How often to re-read the pane while verifying a fresh spawn.
VERIFY_STEP=5

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
  sleep 1
  tmux send-keys -t "$SESSION" Enter
}

# Confirm that a freshly spawned session actually registered with Remote
# Control. Returns 0 once the banner appears; otherwise kills the session so
# the next watchdog pass starts from a clean slate.
verify_session() {
  [ "$VERIFY" -gt 0 ] || return 0

  waited=0
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
    contains "$out" "$READY" && return 0

    if contains "$out" "must be logged in" || contains "$out" "Not logged in"; then
      log "claude reports it is not logged in; Remote Control cannot start."
      log "Run 'claude', then /login with your claude.ai subscription account."
      tmux kill-session -t "$SESSION" 2>/dev/null
      return 1
    fi

    # A machine's first launch hits one-time gates that block until answered,
    # and an unattended session has nobody to answer them: the workspace trust
    # prompt, then — because the default ARGS pass
    # --dangerously-skip-permissions — the Bypass Permissions warning. claude
    # saves both answers, so each fires once per machine. Answering grants
    # nothing those defaults do not already grant; CLAUDE_TMUX_AUTO_TRUST=0
    # opts out and fails the spawn with the reason logged instead.
    #
    # Answer each at most once per spawn: capture-pane reads the scrollback
    # too, so a dismissed prompt stays matchable and an unguarded match would
    # keep typing stray digits into the running session.
    if [ "$trust_answered" -eq 0 ] && contains "$out" "trust this folder"; then
      answer_gate 1 "workspace trust prompt" || return 1
      trust_answered=1
      continue
    fi

    if [ "$bypass_answered" -eq 0 ] && contains "$out" "Bypass Permissions mode"; then
      answer_gate 2 "Bypass Permissions warning" || return 1
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
  status)
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "session '$SESSION': not running"
      exit 1
    fi
    if contains "$(pane_head)" "$READY"; then
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
    die "unknown command: $1 (expected run, start, stop or status)"
    ;;
esac
