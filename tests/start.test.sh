#!/bin/sh
# Exercise claude-remote-start.sh's spawn verification against a stubbed tmux
# in a throwaway HOME, so nothing touches the real machine (this box runs the
# very session the service manages).
#
# claude-remote-start.sh prepends $HOME/.local/bin, linuxbrew, homebrew and
# /usr/local/bin to PATH, so stubs only win from $HOME/.local/bin — the first
# entry. `sleep` is stubbed out too, which is what keeps a 60s verification
# budget running in milliseconds.
set -u

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT=$(mktemp -d)
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ok   — $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL — $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# The stub tmux keeps its whole world in $STATE:
#   session   exists while the session is "running"
#   pane      what capture-pane prints
#   keys      one line per send-keys, in order
#   ready     if present, Enter flips the pane to the ready banner
new_case() {
  CASE=$1
  HOME_DIR="$ROOT/$CASE/home"
  STUBS="$HOME_DIR/.local/bin"
  STATE="$ROOT/$CASE/state"
  OUT="$ROOT/$CASE/out.txt"
  mkdir -p "$STUBS" "$STATE"

  : > "$STATE/pane"
  : > "$STATE/keys"

  cat > "$STUBS/tmux" <<'STUB'
#!/bin/sh
cmd=$1
case "$cmd" in
  has-session)  [ -f "$STATE/session" ] ;;
  new-session)  : > "$STATE/session" ;;
  kill-session) rm -f "$STATE/session" ;;
  capture-pane) cat "$STATE/pane" ;;
  send-keys)
    # send-keys -t <session> <key>
    printf '%s\n' "$4" >> "$STATE/keys"
    if [ "$4" = Enter ] && [ -f "$STATE/ready" ]; then
      cat "$STATE/ready" > "$STATE/pane"
    fi
    ;;
  *) echo "stub tmux: unexpected command: $cmd" >&2; exit 64 ;;
esac
STUB

  # Only has to exist: the script probes it with `command -v claude`, and the
  # stub tmux never actually runs the new-session command line.
  printf '#!/bin/sh\n:\n' > "$STUBS/claude"
  printf '#!/bin/sh\n:\n' > "$STUBS/sleep"
  chmod +x "$STUBS/tmux" "$STUBS/claude" "$STUBS/sleep"
}

run_start() {
  HOME="$HOME_DIR" STATE="$STATE" CLAUDE_TMUX_SESSION=test \
    XDG_CONFIG_HOME="$HOME_DIR/.config" \
    "$@" sh "$REPO/claude-remote-start.sh" start >"$OUT" 2>&1
  RC=$?
}

trust_prompt() {
  cat > "$STATE/pane" <<'PANE'
Accessing workspace:
/Users/ercode
Quick safety check: Is this a project you created or one you trust?
> 1. Yes, I trust this folder
  2. No, exit
PANE
}

echo "claude-remote-start.sh — spawn verification"

# --- the prompt is answered, and the session comes up -----------------------
new_case autotrust
trust_prompt
# Answering scrolls the prompt up rather than erasing it — the banner arrives
# with the prompt still in the scrollback capture-pane reads.
{ cat "$STATE/pane"; echo "remote-control is active"; } > "$STATE/ready"
run_start

check "answered prompt verifies successfully" '[ "$RC" -eq 0 ]'
check "session left running"                  '[ -f "$STATE/session" ]'
check "picked 'Yes, I trust this folder'"     'grep -qx 1 "$STATE/keys"'
check "confirmed with Enter"                  'grep -qx Enter "$STATE/keys"'
check "says what it did"                      'grep -q "answering the workspace trust prompt" "$OUT"'

# --- the prompt lingers in the scrollback and must not be re-answered -------
# Without a guard, every 5s pass would re-match the prompt text still sitting
# in the scrollback and type a stray "1" into the live session.
new_case answered_once
trust_prompt   # never becomes ready, so verification runs its full budget
run_start

check "gives up when the banner never lands" '[ "$RC" -ne 0 ]'
check "recycles the session"                 '[ ! -f "$STATE/session" ]'
check "answers exactly once"                 '[ "$(grep -cx 1 "$STATE/keys")" -eq 1 ]'
check "sends exactly one Enter"              '[ "$(grep -cx Enter "$STATE/keys")" -eq 1 ]'

# --- opting out leaves the prompt alone -------------------------------------
new_case no_autotrust
trust_prompt
run_start env CLAUDE_TMUX_AUTO_TRUST=0

check "opting out fails the spawn"      '[ "$RC" -ne 0 ]'
check "opting out sends no keys"        '[ ! -s "$STATE/keys" ]'
check "opting out recycles the session" '[ ! -f "$STATE/session" ]'
check "opting out explains the prompt"  'grep -q "waiting on the workspace trust prompt" "$OUT"'

# --- an unrelated failure still reports its own cause -----------------------
new_case logged_out
printf 'You must be logged in to use Claude Code\n' > "$STATE/pane"
run_start

check "logged out is diagnosed"           'grep -q "not logged in" "$OUT"'
check "logged out sends no trust keys"    '[ ! -s "$STATE/keys" ]'

rm -rf "$ROOT"
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
