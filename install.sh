#!/bin/sh
# claude-tmux-service installer — Linux (systemd) and macOS (launchd).
#
# One command from a bare machine to a running Remote Control session: it
# installs whatever is missing (tmux, Claude Code, Homebrew on macOS), walks you
# through the claude.ai login, then installs and starts the service.
#
# Nothing is installed behind your back — every privileged command is printed
# before it runs, and --no-deps restores the old check-only behaviour.
set -eu

SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN_DIR="$HOME/.local/bin"
SCRIPT="claude-remote-start.sh"

# The same search path the watchdog uses, so a Claude Code we install below is
# found in this run without restarting the shell. The extra dirs are overridable
# via CLAUDE_TMUX_EXTRA_PATH so the test suite can keep a real host tmux/claude
# (Homebrew installs to /opt/homebrew/bin, which is listed here) from leaking
# into a case meant to simulate their absence. Using ${VAR-default}, not :=,
# lets a test set it empty to drop the extra dirs while leaving it unset in
# normal use to pick up Homebrew and linuxbrew.
EXTRA_PATH=${CLAUDE_TMUX_EXTRA_PATH-/home/linuxbrew/.linuxbrew/bin:/opt/homebrew/bin:/usr/local/bin}
PATH="$HOME/.local/bin${EXTRA_PATH:+:$EXTRA_PATH}:$PATH"
export PATH

WITH_DEPS=1
WITH_LOGIN=1
ASSUME_YES=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

  (no options)  install missing prerequisites, log in if needed, install service
  --no-deps     install nothing; stop if a prerequisite is missing
  --no-login    skip the login step
  -y, --yes     never pause for confirmation (unattended runs)
  -h, --help    this text
EOF
}

for arg in "$@"; do
  case "$arg" in
  --no-deps) WITH_DEPS=0 ;;
  --no-login) WITH_LOGIN=0 ;;
  -y | --yes) ASSUME_YES=1 ;;
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

OS=$(uname -s)

say() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
die() {
  echo "Error: $*" >&2
  exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

# Pause only when a human is present and has not pre-approved. With no terminal
# to ask (CI, a provisioning run) we proceed: the command is printed either way.
confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || return 0
  printf '%s [Y/n] ' "$1"
  read -r reply </dev/tty || return 0
  case "$reply" in
  [nN]*) return 1 ;;
  *) return 0 ;;
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

pkg_hint() {
  if have pacman; then echo "sudo pacman -S tmux"
  elif have apt-get; then echo "sudo apt install tmux"
  elif have dnf; then echo "sudo dnf install tmux"
  elif have zypper; then echo "sudo zypper install tmux"
  elif have apk; then echo "sudo apk add tmux"
  elif have brew; then echo "brew install tmux"
  else echo "install tmux with your package manager"; fi
}

# --- Prerequisite: Homebrew (macOS only) -----------------------------------
# macOS ships no package manager, so on a fresh Mac there is no way to get tmux
# without installing one first.
ensure_brew() {
  have brew && return 0
  say "Homebrew is not installed, and macOS has no other way to install tmux."
  confirm "Install Homebrew now? (it will ask for your password)" || return 1
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Apple Silicon installs to /opt/homebrew, Intel to /usr/local.
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$b" ] && eval "$("$b" shellenv)" && break
  done
  have brew
}

# --- Prerequisite: tmux ----------------------------------------------------
install_tmux() {
  if have pacman; then run_priv pacman -S --needed --noconfirm tmux
  elif have apt-get; then
    run_priv apt-get update
    run_priv apt-get install -y tmux
  elif have dnf; then run_priv dnf install -y tmux
  elif have zypper; then run_priv zypper --non-interactive install tmux
  elif have apk; then run_priv apk add tmux
  elif [ "$OS" = Darwin ]; then
    ensure_brew || return 1
    say "running: brew install tmux"
    brew install tmux
  else
    return 1
  fi
}

ensure_tmux() {
  have tmux && return 0
  [ "$WITH_DEPS" -eq 1 ] || die "tmux is required. Try: $(pkg_hint)"
  say "tmux is not installed."
  confirm "Install tmux now?" || die "tmux is required. Try: $(pkg_hint)"
  install_tmux || die "could not install tmux automatically. Try: $(pkg_hint)"
  have tmux || die "tmux still not found after installing"
}

# --- Prerequisite: Claude Code ---------------------------------------------
ensure_claude() {
  have claude && return 0
  if [ "$WITH_DEPS" -eq 0 ]; then
    warn "'claude' not found in PATH; the service will retry until it is installed."
    return 0
  fi
  have curl || die "curl is required to install Claude Code"
  say "Claude Code is not installed."
  confirm "Install it now with the official installer?" || {
    warn "skipping; the service will retry until 'claude' appears in PATH."
    return 0
  }
  say "running: curl -fsSL https://claude.ai/install.sh | bash"
  curl -fsSL https://claude.ai/install.sh | bash
  have claude || warn "'claude' still not in PATH; open a new shell, or add ~/.local/bin to PATH."
}

# --- Prerequisite: a login Remote Control can actually use ------------------
# `claude auth status --json` is the portable way to ask: on macOS the
# credentials live in the Keychain, on Linux in ~/.claude/.credentials.json,
# and this reads whichever applies.
AUTH_JSON=""
refresh_auth() { AUTH_JSON=$(claude auth status --json 2>/dev/null || true); }
logged_in() { printf '%s\n' "$AUTH_JSON" | grep -q '"loggedIn"[[:space:]]*:[[:space:]]*true'; }
auth_field() {
  printf '%s\n' "$AUTH_JSON" |
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1
}

# Credentials that authenticate fine but cannot open a Remote Control session,
# so the watchdog would loop forever on a machine that looks logged in.
check_credential_kind() {
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    warn "CLAUDE_CODE_OAUTH_TOKEN is set. Tokens from 'claude setup-token' can only"
    warn "make model requests — they cannot establish Remote Control sessions."
    warn "Unset it and log in with a claude.ai subscription instead."
  fi
  for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
    eval "val=\${$v:-}"
    [ -n "$val" ] && {
      warn "$v is set and takes precedence over your subscription login."
      warn "Remote Control needs the subscription; run 'unset $v'."
    }
  done
  [ -n "${ANTHROPIC_BASE_URL:-}" ] &&
    warn "ANTHROPIC_BASE_URL is set; Remote Control requires api.anthropic.com."

  method=$(auth_field authMethod)
  if [ -n "$method" ] && [ "$method" != "claude.ai" ]; then
    warn "logged in via '$method'. Remote Control requires a claude.ai Pro or Max"
    warn "subscription; console/API-billing logins cannot host a session."
  fi
}

ensure_login() {
  [ "$WITH_LOGIN" -eq 1 ] || return 0
  have claude || {
    warn "skipping login check — Claude Code is not installed yet."
    return 0
  }

  refresh_auth
  if logged_in; then
    say "Logged in as $(auth_field email) ($(auth_field subscriptionType))"
    check_credential_kind
    return 0
  fi

  say "Not logged in. Remote Control needs a claude.ai Pro or Max account."
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    warn "no terminal available to run the login flow."
    warn "Run 'claude auth login' yourself, then re-run this installer."
    return 0
  fi

  say "Starting the login flow — approve it in the browser that opens."
  say "Over SSH no browser opens: copy the printed URL, approve it, and paste"
  say "the code back here."
  claude auth login || warn "login did not complete"

  refresh_auth
  if logged_in; then
    say "Logged in as $(auth_field email) ($(auth_field subscriptionType))"
    check_credential_kind
  else
    warn "still not logged in. The service will install, but no session can start"
    warn "until you run 'claude auth login'."
  fi
}

# --- Run -------------------------------------------------------------------
ensure_tmux
ensure_claude
ensure_login

install -d "$BIN_DIR"
install -m 0755 "$SRC_DIR/$SCRIPT" "$BIN_DIR/$SCRIPT"
say "Installed $BIN_DIR/$SCRIPT"

case "$OS" in
Linux)
  have systemctl || die "systemctl not found. This installer targets systemd systems."
  UNIT_DIR="$HOME/.config/systemd/user"
  install -d "$UNIT_DIR"
  install -m 0644 "$SRC_DIR/systemd/claude-tmux.service" "$UNIT_DIR/claude-tmux.service"
  say "Installed $UNIT_DIR/claude-tmux.service"

  # Keep the user service running after logout / across reboots.
  loginctl enable-linger "$USER" 2>/dev/null ||
    warn "could not enable linger; service may not start until you log in."

  systemctl --user daemon-reload
  systemctl --user enable claude-tmux.service
  # Restart rather than `enable --now`: --now is a no-op when the service is
  # already running, so re-running the installer to pick up a new version would
  # report success while the old watchdog (and the claude it spawned) kept
  # running untouched.
  systemctl --user restart claude-tmux.service
  echo
  echo "Done. The service is running."
  echo "  Status:  systemctl --user status claude-tmux.service"
  echo "  Check:   $BIN_DIR/$SCRIPT status"
  echo "  Attach:  tmux attach -t \"\${CLAUDE_TMUX_SESSION:-\$(hostname -s)}\""
  ;;
Darwin)
  AGENT_DIR="$HOME/Library/LaunchAgents"
  PLIST="$AGENT_DIR/com.claude-tmux.plist"
  install -d "$AGENT_DIR" "$HOME/Library/Logs"
  sed "s|__HOME__|$HOME|g" "$SRC_DIR/launchd/com.claude-tmux.plist" >"$PLIST"
  say "Installed $PLIST"

  DOMAIN="gui/$(id -u)"
  launchctl bootout "$DOMAIN/com.claude-tmux" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$PLIST"
  launchctl enable "$DOMAIN/com.claude-tmux" 2>/dev/null || true
  echo
  echo "Done. The service is running."
  echo "  Status:  launchctl print $DOMAIN/com.claude-tmux | head"
  echo "  Check:   $BIN_DIR/$SCRIPT status"
  echo "  Logs:    tail -f \"$HOME/Library/Logs/claude-tmux.log\""
  echo "  Attach:  tmux attach -t \"\${CLAUDE_TMUX_SESSION:-\$(hostname -s)}\""
  ;;
*)
  die "unsupported OS '$OS'. Only Linux (systemd) and macOS are supported."
  ;;
esac
