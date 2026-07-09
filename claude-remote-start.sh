#!/bin/sh
# claude-tmux-service — keep a Claude Code Remote Control session alive in tmux.
#
# Runs as a watchdog: every $CLAUDE_TMUX_INTERVAL seconds it checks whether
# the tmux session exists; if claude exited (network timeout, crash, /exit),
# the session dies and this loop recreates it. When the network comes back,
# the session reconnects within one interval.
#
# Usage:
#   claude-remote-start.sh          run the watchdog loop (used by the service)
#   claude-remote-start.sh start    create the session once and exit
#   claude-remote-start.sh stop     kill the tmux session
#
# Configuration (environment or ~/.config/claude-tmux/env):
#   CLAUDE_TMUX_SESSION    tmux session name        (default: short hostname)
#   CLAUDE_TMUX_ARGS       extra args for claude    (default: --dangerously-skip-permissions)
#   CLAUDE_TMUX_INTERVAL   watchdog check interval  (default: 30 seconds)
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

die() {
  echo "claude-tmux: $*" >&2
  exit 1
}

command -v tmux >/dev/null 2>&1 || die "tmux not found in PATH"

ensure_session() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    return 0
  fi
  if ! command -v claude >/dev/null 2>&1; then
    echo "claude-tmux: claude not found in PATH, will retry" >&2
    return 1
  fi
  # shellcheck disable=SC2086 — ARGS is intentionally word-split
  tmux new-session -d -s "$SESSION" -c "$HOME" \
    claude --remote-control "$SESSION" $ARGS
}

case "${1:-run}" in
  run)
    while :; do
      ensure_session || true
      sleep "$INTERVAL"
    done
    ;;
  start)
    ensure_session
    ;;
  stop)
    tmux kill-session -t "$SESSION" 2>/dev/null || true
    ;;
  *)
    die "unknown command: $1 (expected run, start or stop)"
    ;;
esac
