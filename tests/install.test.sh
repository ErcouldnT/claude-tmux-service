#!/bin/sh
# Exercise install.sh against stubbed tools in a throwaway HOME, so nothing
# touches the real machine (this box runs the very session install.sh restarts).
#
# install.sh deliberately prepends $HOME/.local/bin, linuxbrew, homebrew and
# /usr/local/bin to PATH so it can find a freshly installed claude. That means
# stubs only win if they live in $HOME/.local/bin — the first entry. The base
# PATH is a whitelist of coreutils, so a real tmux/systemctl/claude on this
# machine can never leak into a test.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT=$(mktemp -d)
SAFEBIN="$ROOT/safebin"
PASS=0
FAIL=0

mkdir -p "$SAFEBIN"
for t in id install sed grep head cat dirname chmod mkdir rm ls env sh tr expr; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$SAFEBIN/$t"
done

ok()   { PASS=$((PASS + 1)); echo "  ok   — $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL — $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# $1 = stub name, rest = shell body. Stubs go in $HOME/.local/bin so they beat
# every directory install.sh prepends.
mkstub() {
  name=$1; shift
  printf '#!/bin/sh\n%s\n' "$*" > "$STUBS/$name"
  chmod +x "$STUBS/$name"
}

new_case() {
  CASE=$1
  HOME_DIR="$ROOT/$CASE/home"
  STUBS="$HOME_DIR/.local/bin"
  mkdir -p "$STUBS"
  OUT="$ROOT/$CASE/out.txt"
  echo; echo "== $CASE =="
}

run() {
  env -i HOME="$HOME_DIR" USER=tester PATH="$SAFEBIN" \
    sh "$REPO/install.sh" "$@" >"$OUT" 2>&1
  echo "$?" > "$ROOT/$CASE/rc"
}
run_env() { # run with extra env: run_env VAR=x VAR2=y -- args...
  extra=""
  while [ "$1" != "--" ]; do extra="$extra $1"; shift; done
  shift
  # shellcheck disable=SC2086
  env -i HOME="$HOME_DIR" USER=tester PATH="$SAFEBIN" $extra \
    sh "$REPO/install.sh" "$@" >"$OUT" 2>&1
  echo "$?" > "$ROOT/$CASE/rc"
}
rc() { cat "$ROOT/$CASE/rc"; }

AUTH_OK='{"loggedIn": true, "authMethod": "claude.ai", "email": "a@b.c", "subscriptionType": "pro"}'
AUTH_NO='{"loggedIn": false}'
AUTH_CONSOLE='{"loggedIn": true, "authMethod": "console", "email": "a@b.c"}'

stub_claude() { mkstub claude "case \"\$*\" in 'auth status --json') echo '$1';; esac; exit 0"; }

# ---------------------------------------------------------------- static ---
echo "== static checks =="
check "install.sh parses as POSIX sh" "sh -n '$REPO/install.sh'"
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck clean" "shellcheck -s sh '$REPO/install.sh' >/dev/null 2>&1"
else
  echo "  skip — shellcheck not installed"
fi

# ------------------------------------------------------------------ help ---
new_case help
run --help
check "--help exits 0"            "[ \"\$(rc)\" -eq 0 ]"
check "--help mentions --no-deps" "grep -q -- '--no-deps' '$OUT'"

new_case badopt
run --bogus
check "unknown option exits 1" "[ \"\$(rc)\" -eq 1 ]"

# --------------------------------------------------- linux, everything ok ---
new_case linux_ok
mkstub uname 'echo Linux'
mkstub tmux  'exit 0'
stub_claude "$AUTH_OK"
mkstub systemctl 'echo "systemctl $*" >> "$HOME/systemctl.log"; exit 0'
mkstub loginctl  'echo "loginctl $*"  >> "$HOME/loginctl.log";  exit 0'
run -y
check "exits 0"                "[ \"\$(rc)\" -eq 0 ]"
check "watchdog installed"     "[ -x '$HOME_DIR/.local/bin/claude-remote-start.sh' ]"
check "systemd unit installed" "[ -f '$HOME_DIR/.config/systemd/user/claude-tmux.service' ]"
check "linger enabled"         "grep -q 'enable-linger tester' '$HOME_DIR/loginctl.log'"
check "restarted, not just enable --now" \
      "grep -q 'restart claude-tmux.service' '$HOME_DIR/systemctl.log'"
check "reports the logged-in account" "grep -q 'a@b.c' '$OUT'"
check "reports the plan"              "grep -q 'pro' '$OUT'"
check "no launchd artifacts"          "[ ! -d '$HOME_DIR/Library' ]"

# -------------------------------------------------------- macOS behaviour ---
new_case darwin_ok
mkstub uname 'echo Darwin'
mkstub tmux  'exit 0'
stub_claude "$AUTH_OK"
mkstub launchctl 'echo "launchctl $*" >> "$HOME/launchctl.log"; exit 0'
run -y
PLIST="$HOME_DIR/Library/LaunchAgents/com.claude-tmux.plist"
check "exits 0"               "[ \"\$(rc)\" -eq 0 ]"
check "LaunchAgent installed" "[ -f '$PLIST' ]"
check "Logs dir created"      "[ -d '$HOME_DIR/Library/Logs' ]"
check "__HOME__ substituted"  "! grep -q '__HOME__' '$PLIST'"
check "plist points at real HOME" \
      "grep -q '$HOME_DIR/.local/bin/claude-remote-start.sh' '$PLIST'"
check "bootstrap called"      "grep -q 'bootstrap gui/' '$HOME_DIR/launchctl.log'"
check "old agent booted out first" "grep -q 'bootout gui/' '$HOME_DIR/launchctl.log'"
check "no systemd artifacts"  "[ ! -d '$HOME_DIR/.config/systemd' ]"

# ------------------------------------------------- tmux missing, --no-deps ---
new_case nodeps_no_tmux
mkstub uname 'echo Linux'
stub_claude "$AUTH_OK"
mkstub apt-get 'exit 0'
mkstub systemctl 'exit 0'
mkstub loginctl 'exit 0'
run --no-deps -y
check "fails when tmux missing" "[ \"\$(rc)\" -ne 0 ]"
check "prints the apt hint"     "grep -q 'sudo apt install tmux' '$OUT'"
check "installs nothing"        "[ ! -e '$HOME_DIR/.config/systemd' ]"

# ------------------------------------------ tmux missing, auto-install path ---
new_case autoinstall_tmux
mkstub uname 'echo Linux'
stub_claude "$AUTH_OK"
mkstub systemctl 'exit 0'
mkstub loginctl 'exit 0'
mkstub pacman 'exit 0'
# sudo records the call and materialises tmux, standing in for the real install.
mkstub sudo 'echo "sudo $*" >> "$HOME/sudo.log"
printf "#!/bin/sh\nexit 0\n" > "$(dirname "$0")/tmux"
chmod +x "$(dirname "$0")/tmux"
exit 0'
run -y
check "exits 0 after installing tmux"  "[ \"\$(rc)\" -eq 0 ]"
check "used pacman via sudo"           "grep -q 'pacman -S --needed --noconfirm tmux' '$HOME_DIR/sudo.log'"
check "printed the privileged command" "grep -q 'running: sudo pacman' '$OUT'"
check "went on to install the service" "[ -f '$HOME_DIR/.config/systemd/user/claude-tmux.service' ]"

# ------------------------------------------------------------ logged out ---
new_case logged_out
mkstub uname 'echo Linux'
mkstub tmux 'exit 0'
stub_claude "$AUTH_NO"
mkstub systemctl 'exit 0'
mkstub loginctl 'exit 0'
run -y
check "still installs the service" "[ -f '$HOME_DIR/.config/systemd/user/claude-tmux.service' ]"
check "says not logged in"         "grep -qi 'not logged in' '$OUT'"
check "names the login command"    "grep -q 'claude auth login' '$OUT'"

# ------------------------------------- credential kinds that cannot work ----
new_case oauth_token_trap
mkstub uname 'echo Linux'
mkstub tmux 'exit 0'
stub_claude "$AUTH_OK"
mkstub systemctl 'exit 0'
mkstub loginctl 'exit 0'
run_env CLAUDE_CODE_OAUTH_TOKEN=xxx ANTHROPIC_API_KEY=yyy ANTHROPIC_BASE_URL=http://z -- -y
check "warns setup-token can't do Remote Control" \
      "grep -q 'cannot establish Remote Control' '$OUT'"
check "warns ANTHROPIC_API_KEY takes precedence" \
      "grep -q 'ANTHROPIC_API_KEY is set' '$OUT'"
check "warns about ANTHROPIC_BASE_URL" \
      "grep -q 'ANTHROPIC_BASE_URL is set' '$OUT'"

new_case console_login
mkstub uname 'echo Linux'
mkstub tmux 'exit 0'
stub_claude "$AUTH_CONSOLE"
mkstub systemctl 'exit 0'
mkstub loginctl 'exit 0'
run -y
check "warns a console login cannot host a session" \
      "grep -q 'cannot host a session' '$OUT'"

# ------------------------------------------------------------ unknown OS ---
new_case weird_os
mkstub uname 'echo Plan9'
mkstub tmux 'exit 0'
stub_claude "$AUTH_OK"
run -y
check "rejects unsupported OS" "grep -q \"unsupported OS 'Plan9'\" '$OUT'"
check "exits non-zero"         "[ \"\$(rc)\" -ne 0 ]"

# --------------------------------------------------------------- idempotent ---
new_case rerun
mkstub uname 'echo Linux'
mkstub tmux 'exit 0'
stub_claude "$AUTH_OK"
mkstub systemctl 'echo "systemctl $*" >> "$HOME/systemctl.log"; exit 0'
mkstub loginctl 'exit 0'
run -y
run -y
check "second run exits 0"        "[ \"\$(rc)\" -eq 0 ]"
check "restarts on every run"     "[ \"\$(grep -c 'restart claude-tmux.service' '$HOME_DIR/systemctl.log')\" -eq 2 ]"

echo
echo "================================"
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then rm -rf "$ROOT"; else echo "artifacts kept in $ROOT"; fi
exit "$FAIL"
