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
MAX_BACKOFF="${CLAUDE_TMUX_MAX_BACKOFF:-300}"

# How often to re-read the pane while verifying a fresh spawn.
VERIFY_STEP=5

log() {
  echo "claude-tmux: $*" >&2
}

die() {
  log "$*"
  exit 1
}

command -v tmux >/dev/null 2>&1 || die "tmux not found in PATH"

pane_text() {
  tmux capture-pane -t "$SESSION" -p -S - 2>/dev/null
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

# Confirm that a freshly spawned session actually registered with Remote
# Control. Returns 0 once the banner appears; otherwise kills the session so
# the next watchdog pass starts from a clean slate.
verify_session() {
  [ "$VERIFY" -gt 0 ] || return 0

  waited=0
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
    if contains "$(pane_text)" "$READY"; then
      echo "session '$SESSION': running, registered with Remote Control"
    else
      echo "session '$SESSION': running but NOT registered with Remote Control"
      exit 1
    fi
    ;;
  *)
    die "unknown command: $1 (expected run, start, stop or status)"
    ;;
esac
