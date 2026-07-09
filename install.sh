#!/bin/sh
# claude-tmux-service installer — Linux (systemd) and macOS (launchd).
set -eu

SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN_DIR="$HOME/.local/bin"
SCRIPT="claude-remote-start.sh"

pkg_hint() {
  if command -v pacman >/dev/null 2>&1; then echo "sudo pacman -S tmux";
  elif command -v apt-get >/dev/null 2>&1; then echo "sudo apt install tmux";
  elif command -v dnf >/dev/null 2>&1; then echo "sudo dnf install tmux";
  elif command -v brew >/dev/null 2>&1; then echo "brew install tmux";
  else echo "install tmux with your package manager"; fi
}

# --- Common prerequisites --------------------------------------------------
command -v tmux >/dev/null 2>&1 || {
  echo "Error: tmux is required. Try: $(pkg_hint)" >&2
  exit 1
}
command -v claude >/dev/null 2>&1 || \
  echo "Warning: 'claude' not found in PATH now; the service will retry until it is installed." >&2

install -d "$BIN_DIR"
install -m 0755 "$SRC_DIR/$SCRIPT" "$BIN_DIR/$SCRIPT"
echo "Installed $BIN_DIR/$SCRIPT"

OS=$(uname -s)
case "$OS" in
Linux)
  command -v systemctl >/dev/null 2>&1 || {
    echo "Error: systemctl not found. This installer targets systemd systems." >&2
    exit 1
  }
  UNIT_DIR="$HOME/.config/systemd/user"
  install -d "$UNIT_DIR"
  install -m 0644 "$SRC_DIR/systemd/claude-tmux.service" "$UNIT_DIR/claude-tmux.service"
  echo "Installed $UNIT_DIR/claude-tmux.service"

  # Keep the user service running after logout / across reboots.
  loginctl enable-linger "$USER" 2>/dev/null || \
    echo "Warning: could not enable linger; service may not start until you log in." >&2

  systemctl --user daemon-reload
  systemctl --user enable --now claude-tmux.service
  echo
  echo "Done. The service is running."
  echo "  Status:  systemctl --user status claude-tmux.service"
  echo "  Attach:  tmux attach -t \"\${CLAUDE_TMUX_SESSION:-\$(hostname -s)}\""
  ;;
Darwin)
  AGENT_DIR="$HOME/Library/LaunchAgents"
  PLIST="$AGENT_DIR/com.claude-tmux.plist"
  install -d "$AGENT_DIR" "$HOME/Library/Logs"
  sed "s|__HOME__|$HOME|g" "$SRC_DIR/launchd/com.claude-tmux.plist" > "$PLIST"
  echo "Installed $PLIST"

  DOMAIN="gui/$(id -u)"
  launchctl bootout "$DOMAIN/com.claude-tmux" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$PLIST"
  launchctl enable "$DOMAIN/com.claude-tmux" 2>/dev/null || true
  echo
  echo "Done. The service is running."
  echo "  Status:  launchctl print $DOMAIN/com.claude-tmux | head"
  echo "  Logs:    tail -f \"$HOME/Library/Logs/claude-tmux.log\""
  echo "  Attach:  tmux attach -t \"\${CLAUDE_TMUX_SESSION:-\$(hostname -s)}\""
  ;;
*)
  echo "Error: unsupported OS '$OS'. Only Linux (systemd) and macOS are supported." >&2
  exit 1
  ;;
esac
