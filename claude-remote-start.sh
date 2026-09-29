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
#   claude-remote-start.sh reset    forget the conversation, so the next spawn
#                                   starts an empty one
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
#   CLAUDE_TMUX_RESUME       resume the same conversation across restarts
#                            (default: 1, 0 starts every session empty)
#   CLAUDE_TMUX_RC_OK        status-bar text meaning "registered" (default: /rc)
#   CLAUDE_TMUX_RC_FAILED    status-bar text meaning "registration failed"
#                            (default: /rc failed)
#   CLAUDE_TMUX_HEALTH       re-check an already-running session this often
#                            (default: 300 seconds, 0 disables)
#   CLAUDE_TMUX_HEALTH_STRIKES  consecutive failed checks before recycling
#                            (default: 2)
#   CLAUDE_TMUX_UNKNOWN_STRIKES  consecutive checks with an unreadable status
#                            bar before recycling (default: 6, 0 disables)
#   CLAUDE_TMUX_RESUME_GATE  menu text of the prompt claude raises before
#                            resuming a large conversation
#                            (default: Resume from summary)
#   CLAUDE_TMUX_CHROME       |-separated status-bar text that means claude's
#                            own prompt is on screen, i.e. nothing covers it
#                            (default: bypass permissions|for shortcuts|
#                            shift+tab to cycle|esc to interrupt)
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
RESUME="${CLAUDE_TMUX_RESUME:-1}"
RC_OK="${CLAUDE_TMUX_RC_OK:-/rc}"
RC_FAILED="${CLAUDE_TMUX_RC_FAILED:-/rc failed}"
HEALTH="${CLAUDE_TMUX_HEALTH:-300}"
HEALTH_STRIKES="${CLAUDE_TMUX_HEALTH_STRIKES:-2}"
UNKNOWN_STRIKES="${CLAUDE_TMUX_UNKNOWN_STRIKES:-6}"
RESUME_GATE="${CLAUDE_TMUX_RESUME_GATE:-Resume from summary}"
CHROME="${CLAUDE_TMUX_CHROME:-bypass permissions|for shortcuts|shift+tab to cycle|esc to interrupt}"

# How often to re-read the pane while verifying a fresh spawn.
VERIFY_STEP=5

# A logout is the one failure the watchdog cannot fix on its own: restoring it
# needs an interactive claude.ai login that an unattended service can't perform.
# So when it's detected we leave a marker here — read back by `status` — and
# raise a desktop notification, turning a silently dead service into one that
# says why it stopped and how to revive it.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-tmux"
LOGOUT_MARK="$STATE_DIR/logged-out"

# Every restart the watchdog performs — a crash, a network timeout, a reboot —
# otherwise costs the conversation: claude starts empty and whatever was being
# worked on from the phone is gone. So the session is pinned to one conversation
# id, kept here, and every respawn reattaches to it. Recorded rather than
# derived: `claude --continue` would take the most recent conversation in $HOME,
# which is just as likely to be one the person started by hand in a terminal.
SESSION_ID_FILE="$STATE_DIR/session-id"
# Consecutive spawns that failed while resuming. A transcript claude refuses to
# open would otherwise be retried forever; see resume_failed.
RESUME_FAIL_FILE="$STATE_DIR/resume-failures"
RESUME_FAIL_LIMIT=3
# Conversations the watchdog stopped resuming, one "<time> <id>" per line. The
# transcript is never deleted — only the pointer to it — so this is the list to
# read when a conversation seems to have vanished.
ABANDONED_FILE="$STATE_DIR/abandoned-sessions"
# Settings handed to every spawn: a SessionStart hook that records which
# conversation claude is in *now*. See record_session.
HOOK_FILE="$STATE_DIR/hooks.json"
# This script, absolute, for the hook to call back into.
SELF="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)/$(basename -- "$0")"
# Where claude keeps its transcripts, one directory per working directory.
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

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

# --- conversation continuity ------------------------------------------------

# uuidgen ships with macOS and with util-linux; /proc is the Linux fallback for
# the minimal images that carry neither.
new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'ABCDEF' 'abcdef'
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    _u=""
    read -r _u < /proc/sys/kernel/random/uuid 2>/dev/null
    [ -n "$_u" ] && echo "$_u"
  else
    return 1
  fi
}

# The id reaches a command line unquoted, and it is read back from a file that
# anything could have written, so shape it before trusting it: 8-4-4-4-12 hex.
valid_uuid() {
  case "$1" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      return 0 ;;
  esac
  return 1
}

# read returns non-zero on a file with no trailing newline while still setting
# the variable, so judge the value rather than the exit status — a hand-written
# id file would otherwise look empty.
saved_session_id() {
  [ -f "$SESSION_ID_FILE" ] || return 1
  _id=""
  read -r _id < "$SESSION_ID_FILE" 2>/dev/null
  valid_uuid "${_id:-}" || return 1
  echo "$_id"
}

save_session_id() {
  mkdir -p "$STATE_DIR" 2>/dev/null && echo "$1" > "$SESSION_ID_FILE" 2>/dev/null
  return 0
}

# Stop resuming the pinned conversation. Only the pointer goes: the transcript
# stays where claude wrote it, and its id is appended to $ABANDONED_FILE and
# logged, so "the conversation vanished" is always one `claude --resume` away
# from being undone.
forget_session_id() {
  _old=$(saved_session_id) || _old=""
  if [ -n "$_old" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null &&
      printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$_old" >> "$ABANDONED_FILE" 2>/dev/null
    log "conversation $_old is kept on disk; reopen it with: claude --resume $_old"
  fi
  rm -f "$SESSION_ID_FILE" "$RESUME_FAIL_FILE" 2>/dev/null
  return 0
}

# --- following the conversation claude is actually in ----------------------
#
# The id pinned at spawn time is only right until the conversation changes
# under it. /clear — typed from the phone as easily as here — starts a new
# conversation with a new id, and nothing told the watchdog: the next respawn
# resumed the conversation from *before* the /clear, and everything since
# looked forgotten.
#
# claude says which conversation it is in through a SessionStart hook, which
# fires at startup, on --resume, on /clear and after compaction, with the
# current session_id on stdin. Each spawn is handed a settings file carrying
# that hook (--settings adds to the user's own settings; it replaces nothing),
# and the hook calls back into this script to record the id. A claude started
# by hand in a terminal gets no such hook, so it can never repoint the service.

# POSIX single-quoting, for building the hook's shell command.
sh_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

write_hook_settings() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  _cmd="$(sh_quote "$SELF") record-session $(sh_quote "$SESSION_ID_FILE")"
  _cmd=$(printf '%s' "$_cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' \
    "$_cmd" > "$HOOK_FILE" 2>/dev/null
}

# The hook's side: read claude's JSON from stdin and record its session_id in
# $1. Silent on stdout — SessionStart output is added to the conversation — and
# always successful, so a malformed payload can never get in claude's way.
record_session() {
  _file=${1:-$SESSION_ID_FILE}
  _id=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  valid_uuid "${_id:-}" || return 0
  _prev=""
  [ -f "$_file" ] && read -r _prev < "$_file" 2>/dev/null
  mkdir -p "$(dirname -- "$_file")" 2>/dev/null
  printf '%s\n' "$_id" > "$_file" 2>/dev/null
  # A failure count belongs to the conversation it was charged to.
  [ "${_prev:-}" = "$_id" ] || rm -f "$(dirname -- "$_file")/resume-failures" 2>/dev/null
  return 0
}

# --resume only works on a transcript that exists. Checking first turns the
# common case — the id was recorded but claude never got far enough to write
# anything — into a clean fresh start instead of a spawn that exits instantly.
# The glob covers every project directory rather than reproducing claude's
# rule for encoding a path into a directory name.
transcript_exists() {
  for _t in "$CLAUDE_DIR"/projects/*/"$1.jsonl"; do
    [ -f "$_t" ] && return 0
  done
  return 1
}

# Work out the flags that put the next spawn back into the pinned conversation.
# Assigns two globals rather than printing them: RESUMING has to reach the
# caller so a failure can be judged, and a command substitution would strand it
# in a subshell.
RESUMING=0
RESUME_ARGS=""
set_resume_args() {
  RESUMING=0
  RESUME_ARGS=""
  [ "$RESUME" = 0 ] && return 0

  _id=$(saved_session_id) || _id=""
  if [ -n "$_id" ] && transcript_exists "$_id"; then
    RESUMING=1
    RESUME_ARGS="--resume $_id"
    return 0
  fi

  # Nothing to resume yet. Naming the id up front — rather than letting claude
  # pick one and reading it back — is what makes the *next* restart able to
  # find this conversation.
  _id=$(new_uuid) && valid_uuid "$_id" || {
    log "cannot generate a session id; this conversation will not survive a restart"
    return 0
  }
  save_session_id "$_id"
  RESUME_ARGS="--session-id $_id"
}

# A spawn failed while resuming. Most causes are unrelated to the transcript —
# no network, a logout — and forgetting the conversation over one of those would
# throw away exactly what this feature exists to keep. So count instead, and
# only give up on the transcript once it has failed $RESUME_FAIL_LIMIT times in
# a row; a caller that knows claude rejected the transcript passes `now`.
resume_failed() {
  [ "$RESUMING" -eq 1 ] || return 0
  if [ "${1:-}" != now ] && ! transcript_suspect; then
    return 0
  fi
  if [ "${1:-}" = now ]; then
    log "claude could not reopen the previous conversation; starting a new one"
    forget_session_id
    # There is no longer a conversation to blame, and ensure_session still has
    # its own failing spawn to report: without this the second call would
    # re-create the counter this one just cleared, and the *next* conversation
    # would inherit a failure it never had.
    RESUMING=0
    return 0
  fi
  _n=0
  [ -f "$RESUME_FAIL_FILE" ] && read -r _n < "$RESUME_FAIL_FILE"
  case "${_n:-}" in
    ''|*[!0-9]*) _n=0 ;;
  esac
  _n=$((_n + 1))
  if [ "$_n" -ge "$RESUME_FAIL_LIMIT" ]; then
    log "the previous conversation has failed to start $_n times; starting a new one"
    forget_session_id
    return 0
  fi
  mkdir -p "$STATE_DIR" 2>/dev/null && echo "$_n" > "$RESUME_FAIL_FILE" 2>/dev/null
  return 0
}

resume_succeeded() {
  rm -f "$RESUME_FAIL_FILE" 2>/dev/null
  return 0
}

# Could the conversation be why this spawn failed? Only one failure points
# there: claude dying on its own, straight after start, while signed in. A
# logout, a stuck first-run menu, an expired token or a banner that never
# showed all fail every spawn alike, whatever it resumes — and counting those
# is how a trust prompt this script mis-answered cost a whole conversation.
# FAIL_KIND is set by verify_session.
FAIL_KIND=""
transcript_suspect() {
  [ "$FAIL_KIND" = exited ] || return 1
  # The usual reason for a fast exit is a logout, which is not the
  # transcript's fault either.
  claude auth status --json 2>/dev/null |
    grep -q '"loggedIn"[[:space:]]*:[[:space:]]*true'
}

die() {
  log "$*"
  exit 1
}

# The SessionStart hook calling back in. Handled before anything else, since it
# runs inside claude and must neither fail nor print.
if [ "${1:-}" = record-session ]; then
  record_session "${2:-}"
  exit 0
fi

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

# How many trailing lines of the visible screen count as the status bar.
STATUS_LINES=3

# Claude Code's status bar is the bottom-most chrome in the pane, and it is
# repainted every frame. That makes it the one part of the pane that always
# describes the session as it is *now*: scrollback is history, and with
# --resume the scrollback is somebody else's history entirely.
pane_status() {
  pane_screen | grep -v '^[[:space:]]*$' | tail -n "$STATUS_LINES"
}

# Is this session registered with Remote Control right now? Echoes one of
# active / failed / unknown.
#
# Evidence, strongest first:
#
#   1. The status bar. "/rc" means registered, "/rc failed" means it is not.
#      Checked first, and checked for failure first, because "/rc failed"
#      contains "/rc".
#   2. The opening output, where a fresh spawn prints its banner.
#
# The scrollback is deliberately not evidence, in either direction. Resuming a
# conversation replays its transcript into the pane, so a session that has ever
# discussed its own registration carries both the "remote-control is active"
# banner *and* a "Remote Control disconnected" line in its history, neither of
# which says anything about the present. Trusting the scrollback is what let a
# session sit unregistered for hours while the watchdog read a replayed banner
# and called it healthy.
#
# Absence of evidence stays "unknown" rather than "failed": callers must not
# recycle a working session just because Claude Code renamed its chrome.
registration_state() {
  _bar=$(pane_status)
  if contains "$_bar" "$RC_FAILED"; then
    echo failed
    return 0
  fi
  if contains "$_bar" "$RC_OK"; then
    echo active
    return 0
  fi
  if contains "$(pane_head)" "$READY"; then
    echo active
    return 0
  fi
  echo unknown
}

# Is claude's own prompt chrome — the permission-mode line under the input box —
# on the bottom lines of the screen? Then claude is up and nothing is covering
# it: not wedged behind a full-screen prompt, which is what the "unknown"
# strikes below exist to catch.
#
# This matters because the registration marker is gone. Claude Code no longer
# paints "/rc" in its status bar, busy or idle, and it draws on the alternate
# screen, so there is no scrollback for the startup banner to survive in: a
# healthy session reads "unknown" from the moment the banner scrolls off. Left
# to the strike count, that recycled every session after half an hour of work
# — mid-task — and, with the conversation pointer as it was, back into the
# wrong conversation.
chrome_visible() {
  _bar=$(pane_status)
  _rest=$CHROME
  while [ -n "$_rest" ]; do
    _pat=${_rest%%|*}
    [ -n "$_pat" ] && contains "$_bar" "$_pat" && return 0
    case "$_rest" in
      *"|"*) _rest=${_rest#*|} ;;
      *) _rest="" ;;
    esac
  done
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

# The mark the TUI draws on the highlighted entry of a chooser. Matched
# alongside a plain ">" below, because that is what the same menus rendered
# before, and a watchdog that only knows the current glyph is one redraw away
# from the failure this whole mechanism exists to prevent.
MENU_CURSOR="❯"

# How many Down presses move the highlight from where it sits now onto the
# entry containing $2, reading the visible screen of tmux session $1. Prints a
# signed count — negative means Up — or nothing when either end is missing.
#
# These menus used to be numbered, and typing the number picked an entry
# outright. Claude Code has since dropped the numbers, and the order is not
# fixed either: the workspace trust prompt now opens with "No, exit"
# highlighted. A digit is then ignored and the Enter that follows confirms
# whatever is highlighted — which is exactly how an unattended session answers
# "No, exit" and dies ten seconds after starting, leaving a watchdog to respawn
# it into the same trap forever. Navigating to an entry by its text works
# whichever layout is up, and whichever entry leads, so every caller does that.
#
# Only the visible screen, and only the first cursor on it: a dismissed chooser
# stays in the scrollback, and the prompt box draws the same mark below.
menu_delta() {
  tmux capture-pane -t "$1" -p 2>/dev/null | awk -v t="$2" -v c="$MENU_CURSOR" '
    { n++ }
    !cur && (index($0, c) || $0 ~ /^[ \t]*> /) { cur = n }
    !tgt && index($0, t) { tgt = n }
    END { if (cur && tgt) print tgt - cur }
  '
}

# Move session $1's highlight onto the entry containing $2 and confirm it.
# Returns 1 without touching the session when that entry is not on screen, so a
# caller can report a menu it no longer recognises instead of pressing Enter on
# whatever happens to be selected.
menu_pick() {
  _d=$(menu_delta "$1" "$2")
  case "${_d:-}" in
    ""|*[!0-9-]*) return 1 ;;
  esac
  _key=Down
  if [ "$_d" -lt 0 ]; then
    _key=Up
    _d=$((0 - _d))
  fi
  while [ "$_d" -gt 0 ]; do
    tmux send-keys -t "$1" "$_key"
    sleep 1
    _d=$((_d - 1))
  done
  # Arrow keys only move the highlight, so unlike a digit they never advance
  # the screen on their own: the Enter here is always the one that answers.
  tmux send-keys -t "$1" Enter
  return 0
}

# Answer one of claude's first-run gates by selecting the entry whose text
# contains $1. $2 names the gate in the log. Returns 1, session already killed,
# when auto-answering is switched off or the entry is not on screen, so the
# caller can fail the spawn with the reason on record.
answer_gate() {
  if [ "$AUTO_TRUST" = 0 ]; then
    log "claude is waiting on the $2 for $HOME."
    log "Answer it once by hand, or drop CLAUDE_TMUX_AUTO_TRUST=0 to let the"
    log "watchdog answer it. claude saves the answer either way."
    tmux kill-session -t "$SESSION" 2>/dev/null
    return 1
  fi
  log "answering the $2 for $HOME"
  if menu_pick "$SESSION" "$1"; then
    return 0
  fi
  # Pressing Enter anyway would answer whatever is highlighted, and on both of
  # these menus that is "No, exit". Say what was not found instead: a reworded
  # entry is a one-line fix here, and silence would present as a machine that
  # simply never comes online.
  log "could not find an entry matching '$1' on the $2;"
  log "if Claude Code reworded it, that string is what needs updating."
  tmux kill-session -t "$SESSION" 2>/dev/null
  return 1
}

# The one gate that is not a first-run formality, and the only one that can
# come up on a session that has been running for days.
#
# Pinning the conversation means every respawn resumes it, and a conversation
# only grows. Past a size threshold claude stops resuming outright and asks
# whether to take a summary instead. Nobody watches this pane, so the question
# blocks forever — and because it is a full-screen chooser it covers the
# status bar, which is precisely where registration_state looks. The session
# then reads "unknown" rather than "failed", the health check calls that
# healthy, and the machine sits offline behind a perfectly alive tmux session.
#
# Answer it with "Resume from summary": that keeps the conversation, which is
# the whole point of pinning one, and sheds the weight that raised the question.
#
# Matched on the visible screen, never the scrollback. This gate recurs rather
# than firing once per machine, and with --resume the scrollback is the resumed
# transcript — which, for a conversation that has ever discussed this very
# prompt, contains the phrase verbatim.
resume_gate_up() {
  contains "$(pane_screen)" "$RESUME_GATE"
}

answer_resume_gate() {
  log "answering the resume prompt for '$SESSION' with 'Resume from summary'"
  menu_pick "$SESSION" "Resume from summary" ||
    log "could not find 'Resume from summary' on the resume prompt; leaving it up"
}

# Confirm that a freshly spawned session actually registered with Remote
# Control. Returns 0 once the banner appears; otherwise kills the session so
# the next watchdog pass starts from a clean slate.
verify_session() {
  FAIL_KIND=""
  [ "$VERIFY" -gt 0 ] || return 0

  waited=0
  theme_answered=0
  trust_answered=0
  bypass_answered=0
  # Remote Control can take a moment to come up, and the status bar says
  # "/rc failed" until it does. So a single failed reading is not conclusive
  # here — it is only worth reporting if the whole budget runs out with the
  # session still in that state.
  rc_failed_seen=0
  while [ "$waited" -lt "$VERIFY" ]; do
    sleep "$VERIFY_STEP"
    waited=$((waited + VERIFY_STEP))

    # claude exiting this fast is almost always a login problem: Remote
    # Control refuses to start without a claude.ai subscription session.
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      FAIL_KIND=exited
      log "claude exited ${waited}s after starting."
      log "If this repeats, run 'claude' and check /login — Remote Control needs"
      log "a claude.ai Pro/Max login, not an API key."
      return 1
    fi

    out=$(pane_text)
    case "$(registration_state)" in
      active)
        clear_logged_out
        return 0 ;;
      failed)
        rc_failed_seen=1 ;;
    esac

    # claude rejecting the transcript is the one failure that repeating cannot
    # fix, and it is worth telling apart from a spawn that failed for its own
    # reasons: drop the pinned conversation now rather than after three passes.
    # Usually it exits too fast to be caught here — the pane goes with it — and
    # then resume_failed's counter is what ends the loop.
    if [ "$RESUMING" -eq 1 ] &&
       { contains "$out" "No conversation found" ||
         contains "$out" "No session found" ||
         contains "$out" "Session not found"; }; then
      resume_failed now
      tmux kill-session -t "$SESSION" 2>/dev/null
      return 1
    fi

    if contains "$out" "must be logged in" || contains "$out" "Not logged in"; then
      log "claude reports it is not logged in; Remote Control cannot start."
      log "Run '$0 login' to sign in — it drives 'claude auth login' for you,"
      log "prints the URL, and takes the code you paste back."
      FAIL_KIND=auth
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
      FAIL_KIND=auth
      mark_logged_out
      notify_once "Claude Code needs an interactive sign-in — run claude-remote-start.sh login"
      tmux kill-session -t "$SESSION" 2>/dev/null
      return 1
    fi

    # Not a first-run gate: this one appears on any spawn that resumes a
    # conversation grown past claude's size threshold. Answered before the
    # gates below, which read the scrollback through a screen it is covering.
    if resume_gate_up; then
      answer_resume_gate
      continue
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
      answer_gate "Auto" "theme picker" "Choose the text style" || { FAIL_KIND=gate; return 1; }
      theme_answered=1
      continue
    fi

    if [ "$trust_answered" -eq 0 ] && contains "$out" "trust this folder"; then
      answer_gate "I trust this folder" "workspace trust prompt" "trust this folder" || { FAIL_KIND=gate; return 1; }
      trust_answered=1
      continue
    fi

    if [ "$bypass_answered" -eq 0 ] && contains "$out" "Bypass Permissions mode"; then
      answer_gate "Yes, I accept" "Bypass Permissions warning" "Bypass Permissions mode" || { FAIL_KIND=gate; return 1; }
      bypass_answered=1
      continue
    fi
  done

  if [ "$rc_failed_seen" -eq 1 ]; then
    FAIL_KIND=rc
    # The overwhelmingly common cause: the stored claude.ai token expired while
    # the machine was off or the service was down, so claude starts, runs
    # perfectly well as a local session, and simply never registers. Starting
    # claude again is what refreshes the token, so recycling is the fix — no
    # login needed, which is why this is not treated as a logout.
    log "session '$SESSION' is running but Remote Control registration failed;"
    log "recycling it. Usually an expired claude.ai token — a fresh start"
    log "refreshes it. If it keeps failing, run '$0 login'."
  else
    FAIL_KIND=nobanner
    log "session '$SESSION' started but never showed '$READY' within ${VERIFY}s;"
    log "recycling it. If Claude Code renamed that banner, set CLAUDE_TMUX_READY."
  fi
  tmux kill-session -t "$SESSION" 2>/dev/null
  return 1
}

# Spawn verification only ever looks at a session on its way up. That leaves
# the failure this service exists to prevent wide open: a session that came up
# registered, lost the registration later — the token behind it expires every
# few hours — and kept running as an ordinary local session. tmux still has a
# session, so a watchdog that only asks "does the session exist?" is satisfied
# forever, and the machine quietly stops answering from the Claude app.
#
# So re-check a session that is already up, every $HEALTH seconds. Recycling it
# is the repair: starting claude again refreshes the token.
#
# Two things keep this from fighting a working session. An explicit "failed"
# from the status bar has to say so $HEALTH_STRIKES checks running, so a
# reconnect that is merely in progress is given time to finish. And an
# unreadable status bar — "unknown" — is judged far more slowly still, over
# $UNKNOWN_STRIKES checks, because the cause is usually nothing at all.
#
# "unknown" is nevertheless counted rather than ignored. Leaving it alone
# entirely is what allowed the failure this check exists to catch: claude put a
# full-screen prompt over its own status bar, the reading stopped being
# "failed" and became "unknown", and the wedged session was called healthy for
# two days. Recognised prompts are answered outright (see resume_gate_up); the
# strike count is the backstop for the ones that are not.
# Zero, not "now", so the first pass over an already-running session checks it
# rather than trusting it for $HEALTH seconds. That is the case where trust is
# least earned: the watchdog has just started and has verified nothing.
HEALTH_LAST=0
HEALTH_SEEN=0
UNKNOWN_SEEN=0
session_healthy() {
  [ "$HEALTH" -gt 0 ] || return 0

  _now=$(date +%s 2>/dev/null) || return 0
  [ $((_now - HEALTH_LAST)) -ge "$HEALTH" ] || return 0
  HEALTH_LAST=$_now

  # A prompt that came up long after startup blocks the session exactly as one
  # during startup would, and answering it beats recycling: the conversation
  # survives. Checked before the state is read, because this prompt is what
  # covers the status bar that the reading depends on.
  if resume_gate_up; then
    answer_resume_gate
    return 0
  fi

  _state=$(registration_state)

  if [ "$_state" = active ]; then
    HEALTH_SEEN=0
    UNKNOWN_SEEN=0
    return 0
  fi

  # "unknown" still does not mean "failed" — the status bar can be unreadable
  # for a frame, and Claude Code renaming its chrome must not cost a working
  # session. But it cannot mean "healthy" forever either: a session wedged
  # behind some prompt this script does not recognise reads "unknown" on every
  # single check, and trusting that is what let one sit offline for two days.
  # So tolerate it on a much longer leash than an outright failure, then
  # recycle — the same repair, for a session that is just as stuck.
  if [ "$_state" != failed ]; then
    HEALTH_SEEN=0
    # Unreadable, but claude's own prompt is in plain view: nothing is covering
    # it, so this is the ordinary state of a working session on a Claude Code
    # that no longer shows its registration — not a wedge.
    if chrome_visible; then
      UNKNOWN_SEEN=0
      return 0
    fi
    [ "$UNKNOWN_STRIKES" -gt 0 ] || return 0
    UNKNOWN_SEEN=$((UNKNOWN_SEEN + 1))
    [ "$UNKNOWN_SEEN" -ge "$UNKNOWN_STRIKES" ] || return 0
    log "session '$SESSION' has gone $UNKNOWN_SEEN checks without a readable"
    log "status bar; recycling it. Something is covering it — attach with"
    log "'tmux attach -t $SESSION' if this keeps happening."
    notify_once "Claude session stopped reporting its status — restarting it."
    UNKNOWN_SEEN=0
    tmux kill-session -t "$SESSION" 2>/dev/null
    return 1
  fi

  UNKNOWN_SEEN=0
  HEALTH_SEEN=$((HEALTH_SEEN + 1))
  if [ "$HEALTH_SEEN" -lt "$HEALTH_STRIKES" ]; then
    log "session '$SESSION' reports a failed Remote Control registration;"
    log "re-checking in ${HEALTH}s before recycling it."
    return 0
  fi

  log "session '$SESSION' has been unregistered for $HEALTH_SEEN checks;"
  log "recycling it. Usually an expired claude.ai token — a fresh start"
  log "refreshes it."
  notify_once "Remote Control registration dropped — restarting the Claude session."
  HEALTH_SEEN=0
  tmux kill-session -t "$SESSION" 2>/dev/null
  return 1
}

ensure_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    # Recycled: report the failure so the caller waits before respawning,
    # rather than racing the session it just killed.
    session_healthy || return 1
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

  set_resume_args

  # Built up in "$@" so the settings path stays one word even with a space in
  # $HOME; RESUME_ARGS and ARGS are word-split on purpose.
  set -- claude --remote-control "$SESSION"
  # shellcheck disable=SC2086
  [ -n "$RESUME_ARGS" ] && set -- "$@" $RESUME_ARGS
  if [ "$RESUME" != 0 ]; then
    if write_hook_settings; then
      set -- "$@" --settings "$HOOK_FILE"
    else
      log "cannot write $HOOK_FILE; a /clear will not be followed across restarts"
    fi
  fi
  # shellcheck disable=SC2086
  set -- "$@" $ARGS

  tmux new-session -d -s "$SESSION" -c "$HOME" "$@" || {
      log "tmux new-session failed, will retry"
      return 1
    }

  if verify_session; then
    resume_succeeded
    return 0
  fi
  resume_failed
  return 1
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
# The first-run flow puts the sign-in URL on a line of its own; `claude auth
# login` prefixes it with "If the browser didn't open, visit: ". So find it
# anywhere on the line rather than anchoring at the start, and keep the
# continuation rule for the case where it still wraps.
login_url() {
  login_pane | awk '
    {
      if (more) {
        if ($0 ~ /^[^ 	]+$/) { url = url $0; next }
        more = 0
      }
      if (match($0, /https:\/\/[^ 	]+/)) {
        cand = substr($0, RSTART, RLENGTH)
        if (cand ~ /oauth/) { url = cand; more = 1 }
      }
    }
    END { if (url != "") print url }
  '
}

# Select the entry containing $1, on the menu named $2. Same shape as
# answer_gate, and navigating for the same reason: these menus are no longer
# numbered, so a digit is ignored and the Enter behind it would confirm
# whatever leads — on two of them, "No, exit".
login_pick() {
  echo "  answering the $2" >&2
  menu_pick "$LOGIN_SESSION" "$1" ||
    echo "  could not find an entry matching '$1' on the $2" >&2
}

onboarding_done() {
  [ -f "$ONBOARD_STATE" ] || return 1
  grep -q '"hasCompletedOnboarding"[[:space:]]*:[[:space:]]*true' "$ONBOARD_STATE"
}

# Whether there is a live claude.ai session behind that onboarding. These are
# different facts, and treating the first as proof of the second is what made
# `login` useless on the one machine it exists for: hasCompletedOnboarding is
# written once and stays true forever, so a box that onboarded months ago and
# has since had its token expire reported "Setup complete" instantly, never
# reached the code step, and left the service exactly as logged out as it
# found it.
logged_in() {
  claude auth status 2>/dev/null |
    grep -q '"loggedIn"[[:space:]]*:[[:space:]]*true'
}

# What `login` is actually trying to reach.
setup_done() {
  onboarding_done && logged_in
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
  if onboarding_done; then
    # Nothing is left to onboard: only the token lapsed. The TUI will not offer
    # a login menu in that state — it opens as an ordinary session and does not
    # complain until something needs the network — so there is no screen here
    # to drive. Ask for the sign-in directly. The loop below still works, since
    # `claude auth login` prints the same URL and waits at the same "Paste code
    # here" prompt.
    echo "Signing in to claude.ai..." >&2
    tmux new-session -d -s "$LOGIN_SESSION" -x 200 -y 50 -c "$HOME" \
      claude auth login --claudeai || die "could not start the login session"
  else
    # shellcheck disable=SC2086 — ARGS is intentionally word-split
    tmux new-session -d -s "$LOGIN_SESSION" -x 200 -y 50 -c "$HOME" \
      claude $ARGS || die "could not start the login session"
    echo "Walking Claude Code's first-run setup..." >&2
  fi

  code_sent=0
  waited=0

  while [ "$waited" -lt "$LOGIN_BUDGET" ]; do
    # Checked before the has-session test below, so the auth path — where a
    # successful sign-in ends by exiting — is read as the success it is.
    if setup_done; then
      echo "Signed in." >&2
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
      login_pick "Auto" "theme picker" "Choose the text style"
      sleep 3
      continue
    fi

    if contains "$screen" "Select login method"; then
      login_pick "Claude account with subscription" "login method" "Select login method"
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
      login_pick "I trust this folder" "workspace trust prompt" "trust this folder"
      sleep 3
      continue
    fi

    if contains "$screen" "Bypass Permissions mode"; then
      login_pick "Yes, I accept" "Bypass Permissions warning" "Bypass Permissions mode"
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
    # The conversation id is deliberately left in place: stopping the session
    # is not the same as abandoning what it was doing, and `start` should pick
    # the thread back up. `reset` is how you ask for a clean slate.
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    ;;
  reset)
    forget_session_id
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    echo "conversation forgotten; the next session starts empty."
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
    state=$(registration_state)
    if [ "$state" = active ]; then
      clear_logged_out
      echo "session '$SESSION': running, registered with Remote Control"
      if [ "$RESUME" != 0 ] && id=$(saved_session_id); then
        echo "conversation $id — kept across restarts"
      fi
    elif [ "$state" = failed ]; then
      echo "session '$SESSION': running, but Remote Control registration FAILED."
      echo "Usually an expired claude.ai token. The watchdog recycles the session"
      echo "on its own; '$0 stop' then 'start' does it now."
      exit 1
    elif chrome_visible; then
      # Exit 2 as below: claude is up and uncovered, but this version of it
      # does not show whether Remote Control is registered.
      echo "session '$SESSION': running; registration not shown by this Claude Code"
      echo "version — check the Claude app."
      if [ "$RESUME" != 0 ] && id=$(saved_session_id); then
        echo "conversation $id — kept across restarts"
      fi
      exit 2
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
    die "unknown command: $1 (expected run, start, stop, reset, status, login or record-session)"
    ;;
esac
