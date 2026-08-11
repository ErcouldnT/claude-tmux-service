#!/bin/sh
# Exercise uninstall.sh against stubbed tools in a throwaway HOME, so nothing
# touches the real machine (this box runs the very session it would tear down).
#
# uninstall.sh prepends $HOME/.local/bin and the package-manager prefixes to
# PATH, so stubs only win from $HOME/.local/bin — the first entry. The base PATH
# is a whitelist of coreutils, and CLAUDE_TMUX_EXTRA_PATH= drops the Homebrew
# dirs, so a real tmux/claude/brew on this machine can never leak into a case.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT=$(mktemp -d)
SAFEBIN="$ROOT/safebin"
PASS=0
FAIL=0

mkdir -p "$SAFEBIN"
for t in id rm mkdir cat grep head sed ls chmod sh env uname hostname printf expr; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$SAFEBIN/$t"
done

ok()   { PASS=$((PASS + 1)); echo "  ok   — $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL — $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# $1 = stub name, rest = shell body. Stubs land in $HOME/.local/bin so they beat
# every directory uninstall.sh prepends. Each logs its call to $LOG, which is
# how order-of-operations gets asserted.
mkstub() {
  name=$1; shift
  printf '#!/bin/sh\necho "%s $*" >> "%s"\n%s\n' "$name" "$LOG" "$*" > "$STUBS/$name"
  chmod +x "$STUBS/$name"
}

new_case() {
  CASE=$1
  HOME_DIR="$ROOT/$CASE/home"
  STUBS="$HOME_DIR/.local/bin"
  LOG="$ROOT/$CASE/calls.log"
  OUT="$ROOT/$CASE/out.txt"
  mkdir -p "$STUBS" "$HOME_DIR/.config/systemd/user"
  : > "$LOG"
  echo; echo "== $CASE =="

  # A fully installed machine: unit, watchdog script, config and state.
  : > "$HOME_DIR/.config/systemd/user/claude-tmux.service"
  printf '#!/bin/sh\necho "watchdog $*" >> "%s"\n' "$LOG" > "$STUBS/claude-remote-start.sh"
  chmod +x "$STUBS/claude-remote-start.sh"
  mkdir -p "$HOME_DIR/.config/claude-tmux" "$HOME_DIR/.local/state/claude-tmux"
  : > "$HOME_DIR/.config/claude-tmux/env"
  : > "$HOME_DIR/.local/state/claude-tmux/logged-out"

  mkstub systemctl ':'
  mkstub loginctl 'case "$*" in *show-user*) echo "Linger=yes";; esac'
  mkstub tmux 'exit 0'
  mkstub claude ':'
  # A native Claude Code install, for the --remove-claude case to find. The
  # binary keeps logging its calls, so "did it log out?" stays answerable.
  mkdir -p "$HOME_DIR/.local/share/claude/versions"
  : > "$HOME_DIR/.claude.json"
  mkdir -p "$HOME_DIR/.claude"
}

run() {
  env -i HOME="$HOME_DIR" USER=tester PATH="$SAFEBIN" CLAUDE_TMUX_EXTRA_PATH= \
    CLAUDE_TMUX_SESSION=test LOG="$LOG" \
    sh "$REPO/uninstall.sh" "$@" >"$OUT" 2>&1
  echo "$?" > "$ROOT/$CASE/rc"
}
rc() { cat "$ROOT/$CASE/rc"; }

# The stubs write "<name> <args>" per call; these ask where one landed.
line_of() { grep -n "$1" "$LOG" | head -n1 | cut -d: -f1; }

echo "uninstall.sh"
echo "== static checks =="
check "parses as POSIX sh" "sh -n '$REPO/uninstall.sh'"
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck clean" "shellcheck -s sh '$REPO/uninstall.sh' >/dev/null 2>&1"
else
  echo "  skip — shellcheck not installed"
fi

# ------------------------------------------------------------------ help ---
new_case help
run --help
check "help exits 0"        '[ "$(rc)" -eq 0 ]'
check "help lists --all"    'grep -q -- "--all" "$OUT"'
check "help warns on shared tools" 'grep -q "shared with everything else" "$OUT"'
check "help touches nothing" '[ -f "$STUBS/claude-remote-start.sh" ]'

new_case badopt
run --wat
check "unknown option exits 1"  '[ "$(rc)" -eq 1 ]'
check "unknown option is named" 'grep -q "Unknown option: --wat" "$OUT"'

# ------------------------------------------------------- the service goes ---
new_case default
run --yes
check "service disabled"       'grep -q "systemctl --user disable --now claude-tmux.service" "$LOG"'
check "unit file removed"      '[ ! -f "$HOME_DIR/.config/systemd/user/claude-tmux.service" ]'
check "daemon reloaded"        'grep -q "daemon-reload" "$LOG"'
check "session stopped"        'grep -q "watchdog stop" "$LOG"'
check "watchdog script removed" '[ ! -f "$STUBS/claude-remote-start.sh" ]'

# The whole point of the ordering: a watchdog still running when its session is
# killed spawns a replacement that then outlives the uninstall.
check "service stopped before the session" \
  '[ "$(line_of "disable --now")" -lt "$(line_of "watchdog stop")" ]'

# ------------------------------------------------------- our own leftovers ---
check "config removed"  '[ ! -d "$HOME_DIR/.config/claude-tmux" ]'
check "state removed"   '[ ! -d "$HOME_DIR/.local/state/claude-tmux" ]'
check "linger disabled" 'grep -q "loginctl disable-linger" "$LOG"'

new_case keepers
run --yes --keep-config --keep-state --keep-linger
check "config kept"      '[ -d "$HOME_DIR/.config/claude-tmux" ]'
check "state kept"       '[ -d "$HOME_DIR/.local/state/claude-tmux" ]'
check "linger left on"   '! grep -q "disable-linger" "$LOG"'
check "service still goes" '[ ! -f "$HOME_DIR/.config/systemd/user/claude-tmux.service" ]'

# --------------------------------------------------- shared tools are safe ---
# -y is "don't ask me about my own files", not "take the machine apart". With
# no tty the shared-tool questions must answer themselves with no.
new_case shared_safe
run --yes
check "does not log out"        '! grep -q "auth logout" "$LOG"'
check "leaves Claude Code"      '[ -x "$STUBS/claude" ]'
check "leaves Claude data"      '[ -f "$HOME_DIR/.claude.json" ]'
check "leaves tmux alone"       '! grep -q "pacman\|apt-get\|brew uninstall" "$LOG"'

# ------------------------------------------------------------------- all ---
new_case all
run --all
check "logs out"             'grep -q "claude auth logout" "$LOG"'
check "removes the binary"   '[ ! -e "$STUBS/claude" ]'
check "removes versions dir" '[ ! -d "$HOME_DIR/.local/share/claude" ]'
check "removes data"         '[ ! -e "$HOME_DIR/.claude.json" ] && [ ! -d "$HOME_DIR/.claude" ]'
# The logout runs through the binary and is guarded by `have claude`, so a
# recorded logout is itself the proof that the binary was still there when it
# ran — reverse the two steps and this call disappears rather than failing.
check "logs out while the binary still exists" '[ -n "$(line_of "auth logout")" ]'

new_case logout_only
run --yes --logout
check "logs out"           'grep -q "claude auth logout" "$LOG"'
check "but keeps the binary" '[ -x "$STUBS/claude" ]'
check "and keeps the data" '[ -f "$HOME_DIR/.claude.json" ]'

new_case tmux_removal
mkstub pacman ':'
mkstub sudo 'shift; "$@"'
# Two sessions: the service's own, and somebody else's work.
mkstub tmux 'case "$*" in *list-sessions*) echo "test: 1 windows"; echo "work: 3 windows";; esac'
run --yes --remove-tmux
check "uses the package manager"   'grep -q "pacman -Rns" "$LOG"'
check "warns about other sessions" 'grep -q "other tmux session" "$OUT"'
check "counts only the others"     'grep -q "1 other tmux session" "$OUT"'

# ------------------------------------------------- half-installed machines ---
# Re-running after a successful uninstall, or on a machine that was only ever
# half set up, must be a no-op rather than an error.
new_case idempotent
rm -f "$STUBS/claude-remote-start.sh" "$HOME_DIR/.config/systemd/user/claude-tmux.service"
rm -rf "$HOME_DIR/.config/claude-tmux" "$HOME_DIR/.local/state/claude-tmux"
run --yes
check "second run exits 0"     '[ "$(rc)" -eq 0 ]'
check "second run says Done"   'grep -q "Done." "$OUT"'
check "no config question"     '! grep -q "Left .*claude-tmux in place" "$OUT"'

echo
echo "$PASS passed, $FAIL failed"
rm -rf "$ROOT"
[ "$FAIL" -eq 0 ]
