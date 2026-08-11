#!/bin/sh
# claude-tmux-service uninstaller — Linux (systemd) and macOS (launchd).
#
# The service, its unit and the watchdog script always go: that is what running
# this means. Everything else is asked about, because everything else is either
# yours (your config, your claude.ai login) or shared with the rest of the
# machine (Claude Code, tmux). Nothing shared is removed unless you say so, and
# with no terminal to ask — CI, a provisioning run — the answer to those is no.
#
# Same PATH story as install.sh: ~/.local/bin plus the usual package-manager
# prefixes, overridable via CLAUDE_TMUX_EXTRA_PATH so the tests can keep a real
# host tmux or claude out of a case that stubs them.
set -u

EXTRA_PATH=${CLAUDE_TMUX_EXTRA_PATH-/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin:/usr/local/bin}
PATH="$HOME/.local/bin${EXTRA_PATH:+:$EXTRA_PATH}:$PATH"
export PATH

BIN_DIR="$HOME/.local/bin"
SCRIPT="claude-remote-start.sh"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-tmux"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-tmux"
SESSION="${CLAUDE_TMUX_SESSION:-$(hostname -s 2>/dev/null || echo claude)}"

ASSUME_YES=0
KEEP_CONFIG=0
KEEP_STATE=0
KEEP_LINGER=0
DO_LOGOUT=-1
DO_RM_CLAUDE=-1
DO_RM_DATA=-1
DO_RM_TMUX=-1

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [options]

  (no options)     remove the service, then ask about everything else

  -y, --yes        don't ask: remove the service, config, state and linger,
                   and keep Claude Code, tmux and your claude.ai login
      --all        -y plus log out of claude.ai and remove Claude Code,
                   its data and tmux. Read what that means below.

      --keep-config    leave ~/.config/claude-tmux
      --keep-state     leave the watchdog's state dir
      --keep-linger    leave `loginctl enable-linger` on
      --logout         log out of claude.ai
      --remove-claude  uninstall Claude Code itself
      --remove-data    delete ~/.claude and ~/.claude.json
      --remove-tmux    uninstall tmux
  -h, --help       this text

Claude Code, its data and tmux are shared with everything else on this machine;
--all removes them for every tool that was using them, not just this service.
EOF
}

for arg in "$@"; do
  case "$arg" in
  -y | --yes) ASSUME_YES=1 ;;
  --all)
    ASSUME_YES=1
    DO_LOGOUT=1
    DO_RM_CLAUDE=1
    DO_RM_DATA=1
    DO_RM_TMUX=1
    ;;
  --keep-config) KEEP_CONFIG=1 ;;
  --keep-state) KEEP_STATE=1 ;;
  --keep-linger) KEEP_LINGER=1 ;;
  --logout) DO_LOGOUT=1 ;;
  --remove-claude) DO_RM_CLAUDE=1 ;;
  --remove-data) DO_RM_DATA=1 ;;
  --remove-tmux) DO_RM_TMUX=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown option: $arg" >&2
    usage >&2
    exit 1
    ;;
  esac
done

say() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# Two questions with opposite defaults, because the two kinds of thing being
# removed carry opposite risks.
#
# ask_yes covers what this service put there: saying no is a deliberate "leave
# my config alone", so an unattended run should go ahead and clean it up.
ask_yes() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || return 0
  printf '%s [Y/n] ' "$1"
  read -r reply </dev/tty || return 0
  case "$reply" in
  [nN]*) return 1 ;;
  *) return 0 ;;
  esac
}

# ask_no covers what the rest of the machine shares. Here silence must mean no:
# an unattended uninstall that helpfully removed tmux would take out every other
# session on the box. --all, or the matching flag, is the only way to yes.
ask_no() {
  case "$1" in
  1) return 0 ;;
  0) return 1 ;;
  esac
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$2"
  read -r reply </dev/tty || return 1
  case "$reply" in
  [yY]*) return 0 ;;
  *) return 1 ;;
  esac
}

SUDO=""
if [ "$(id -u)" -ne 0 ] && have sudo; then SUDO="sudo"; fi
run_priv() {
  if [ -n "$SUDO" ]; then
    say "running: sudo $*"
    $SUDO "$@"
  else
    say "running: $*"
    "$@"
  fi
}

OS=$(uname -s)

# --- the service itself ------------------------------------------------------
# Stop the watchdog before killing its session, not after. The other order
# leaves a live watchdog for the moment it takes to reach the unit, and a
# watchdog whose session has just vanished does exactly what it is built to do:
# spawn another one, which then outlives the uninstall.
case "$OS" in
Linux)
  if have systemctl; then
    systemctl --user disable --now claude-tmux.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/claude-tmux.service"
    systemctl --user daemon-reload 2>/dev/null || true
    say "Removed the systemd user service"
  fi
  ;;
Darwin)
  launchctl bootout "gui/$(id -u)/com.claude-tmux" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.claude-tmux.plist"
  say "Removed the launchd agent"
  ;;
esac

# The unit's ExecStop already runs this, but only if the service was loaded and
# running — a half-installed machine, or one where the unit was removed by hand,
# still has the session to clear.
if [ -x "$BIN_DIR/$SCRIPT" ]; then
  "$BIN_DIR/$SCRIPT" stop 2>/dev/null || true
fi

rm -f "$BIN_DIR/$SCRIPT"
say "Removed $BIN_DIR/$SCRIPT"

# --- our own leftovers -------------------------------------------------------
if [ -d "$CONFIG_DIR" ]; then
  if [ "$KEEP_CONFIG" -eq 0 ] && ask_yes "Remove your settings at $CONFIG_DIR?"; then
    rm -rf "$CONFIG_DIR"
    say "Removed $CONFIG_DIR"
  else
    say "Left $CONFIG_DIR in place"
  fi
fi

if [ -d "$STATE_DIR" ]; then
  if [ "$KEEP_STATE" -eq 0 ] && ask_yes "Remove the watchdog's state at $STATE_DIR?"; then
    rm -rf "$STATE_DIR"
    say "Removed $STATE_DIR"
  else
    say "Left $STATE_DIR in place"
  fi
fi

# Linger is switched on by install.sh so the user service survives logout. It is
# machine-wide, though, not ours: anything else the user runs as a user service
# is relying on it too, so this asks rather than assuming.
if [ "$OS" = Linux ] && have loginctl && [ "$KEEP_LINGER" -eq 0 ]; then
  if [ "$(loginctl show-user "$(id -un)" --property=Linger 2>/dev/null)" = "Linger=yes" ]; then
    if ask_yes "Disable lingering for $(id -un)? (other user services rely on it too)"; then
      loginctl disable-linger "$(id -un)" 2>/dev/null ||
        run_priv loginctl disable-linger "$(id -un)" 2>/dev/null ||
        warn "could not disable linger"
      say "Disabled lingering"
    else
      say "Left lingering enabled"
    fi
  fi
fi

# --- shared with the rest of the machine -------------------------------------
# Log out before Claude Code goes: the logout runs through the binary, so the
# other order leaves the credentials on disk with nothing left to clear them.
if have claude && ask_no "$DO_LOGOUT" "Log out of claude.ai on this machine?"; then
  claude auth logout >/dev/null 2>&1 && say "Logged out of claude.ai" ||
    warn "claude auth logout failed"
fi

if have claude && ask_no "$DO_RM_CLAUDE" "Uninstall Claude Code itself?"; then
  removed=0
  # Match how it was installed. A native install is a directory the user owns;
  # the package-manager ones have to go back through the manager, or their
  # metadata is left describing a binary that is no longer there.
  if [ -x "$HOME/.local/bin/claude" ] && [ -d "$HOME/.local/share/claude" ]; then
    rm -f "$HOME/.local/bin/claude"
    rm -rf "$HOME/.local/share/claude"
    say "Removed the native Claude Code install"
    removed=1
  fi
  if [ "$removed" -eq 0 ] && have brew && brew list --cask claude-code >/dev/null 2>&1; then
    brew uninstall --cask claude-code && say "Removed the Homebrew cask" && removed=1
  fi
  if [ "$removed" -eq 0 ] && have npm && npm ls -g --depth=0 2>/dev/null | grep -q claude-code; then
    npm uninstall -g @anthropic-ai/claude-code && say "Removed the npm package" && removed=1
  fi
  [ "$removed" -eq 1 ] || warn "could not tell how Claude Code was installed; left it alone"
fi

# Separate from the binary: this is conversation history and credentials, which
# someone reinstalling would want to keep.
if ask_no "$DO_RM_DATA" "Delete Claude Code's data (~/.claude and ~/.claude.json)?"; then
  rm -rf "$HOME/.claude" "$HOME/.claude.json"
  say "Removed Claude Code's data"
fi

# tmux last, and only on an explicit yes. Every other tmux session on the
# machine dies with it, which is rarely what someone removing one service wants.
if have tmux && ask_no "$DO_RM_TMUX" "Uninstall tmux? (kills every tmux session on this machine)"; then
  others=$(tmux list-sessions 2>/dev/null | grep -cv "^$SESSION:" || true)
  [ "${others:-0}" -gt 0 ] && warn "$others other tmux session(s) are running and will be lost"
  if have brew && brew list tmux >/dev/null 2>&1; then
    brew uninstall tmux && say "Removed tmux"
  elif have pacman; then
    run_priv pacman -Rns --noconfirm tmux && say "Removed tmux"
  elif have apt-get; then
    run_priv apt-get remove -y tmux && say "Removed tmux"
  elif have dnf; then
    run_priv dnf remove -y tmux && say "Removed tmux"
  elif have zypper; then
    run_priv zypper --non-interactive remove tmux && say "Removed tmux"
  else
    warn "no known package manager; left tmux alone"
  fi
fi

echo
echo "Done."
