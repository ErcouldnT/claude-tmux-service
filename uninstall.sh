#!/bin/sh
# claude-tmux-service uninstaller — Linux (systemd) and macOS (launchd).
set -eu

BIN_DIR="$HOME/.local/bin"
SCRIPT="claude-remote-start.sh"

# Kill the tmux session (best effort) before removing the script.
[ -x "$BIN_DIR/$SCRIPT" ] && "$BIN_DIR/$SCRIPT" stop 2>/dev/null || true

OS=$(uname -s)
case "$OS" in
Linux)
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now claude-tmux.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/claude-tmux.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  ;;
Darwin)
  launchctl bootout "gui/$(id -u)/com.claude-tmux" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.claude-tmux.plist"
  ;;
esac

rm -f "$BIN_DIR/$SCRIPT"
echo "Removed claude-tmux-service."
echo "Note: config at ~/.config/claude-tmux/ (if any) was left untouched."
