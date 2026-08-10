#!/bin/sh
# Exercise claude-remote-start.sh's spawn verification and status reporting
# against a stubbed tmux in a throwaway HOME, so nothing touches the real
# machine (this box runs the very session the service manages).
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
#   session  exists while the session is "running"
#   pane     what capture-pane prints for the full scrollback
#   head     what capture-pane prints for the opening stretch of history
#   keys     one line per send-keys, in order
#   stepN    pane contents after the Nth Enter, standing in for claude
#            advancing to the next screen; absent means nothing changes
#   hist     history_size to report
#   limit    history_limit to report
new_case() {
  CASE=$1
  HOME_DIR="$ROOT/$CASE/home"
  STUBS="$HOME_DIR/.local/bin"
  STATE="$ROOT/$CASE/state"
  OUT="$ROOT/$CASE/out.txt"
  mkdir -p "$STUBS" "$STATE"

  : > "$STATE/pane"
  : > "$STATE/head"
  : > "$STATE/keys"
  echo 10   > "$STATE/hist"
  echo 2000 > "$STATE/limit"

  cat > "$STUBS/tmux" <<'STUB'
#!/bin/sh
cmd=$1
case "$cmd" in
  has-session)  [ -f "$STATE/session" ] ;;
  new-session)  : > "$STATE/session" ;;
  kill-session) rm -f "$STATE/session" ;;
  capture-pane)
    # A capture with -E is pane_head asking for the opening history only;
    # without it, pane_text asking for everything.
    if [ $# -ge 8 ]; then cat "$STATE/head"; else cat "$STATE/pane"; fi
    ;;
  display-message)
    # display-message -p -t <session> <format>
    case "$5" in
      '#{history_size}')  cat "$STATE/hist" ;;
      '#{history_limit}') cat "$STATE/limit" ;;
      *) echo "stub tmux: unexpected format: $5" >&2; exit 64 ;;
    esac
    ;;
  send-keys)
    # send-keys -t <session> <key>
    printf '%s\n' "$4" >> "$STATE/keys"
    if [ "$4" = Enter ]; then
      n=$(cat "$STATE/step" 2>/dev/null || echo 0)
      n=$((n + 1))
      if [ -f "$STATE/step$n" ]; then
        cat "$STATE/step$n" > "$STATE/pane"
        echo "$n" > "$STATE/step"
      fi
    fi
    ;;
  *) echo "stub tmux: unexpected command: $cmd" >&2; exit 64 ;;
esac
STUB

  # Only has to exist: the script probes it with `command -v claude`, and the
  # stub tmux never actually runs the new-session command line.
  printf '#!/bin/sh\n:\n' > "$STUBS/claude"
  printf '#!/bin/sh\n:\n' > "$STUBS/sleep"

  # Stub the notifier the script reaches for first, so its logout notification
  # is captured here instead of firing a real desktop alert off this box —
  # osascript is a live binary on the macOS running these tests. Recording the
  # message lets a case assert on it.
  cat > "$STUBS/terminal-notifier" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$STATE/notify"
STUB
  chmod +x "$STUBS/tmux" "$STUBS/claude" "$STUBS/sleep" "$STUBS/terminal-notifier"
}

run_cmd() {
  cmd=$1; shift
  HOME="$HOME_DIR" STATE="$STATE" CLAUDE_TMUX_SESSION=test \
    XDG_CONFIG_HOME="$HOME_DIR/.config" \
    XDG_STATE_HOME="$HOME_DIR/.local/state" \
    "$@" sh "$REPO/claude-remote-start.sh" "$cmd" >"$OUT" 2>&1
  RC=$?
}

# Where mark_logged_out drops its marker, given the XDG_STATE_HOME above.
logout_mark() { echo "$HOME_DIR/.local/state/claude-tmux/logged-out"; }

# Each writes its screen to the file named by $1, so a case can build up the
# scrollback the way claude does: a dismissed prompt scrolls up, it does not
# disappear.
trust_prompt() {
  cat >> "$1" <<'PANE'
Accessing workspace:
/Users/ercode
Quick safety check: Is this a project you created or one you trust?
> 1. Yes, I trust this folder
  2. No, exit
PANE
}

bypass_prompt() {
  cat >> "$1" <<'PANE'
WARNING: Claude Code running in Bypass Permissions mode
In Bypass Permissions mode, Claude Code will not ask for your approval before
running potentially dangerous commands.
> 1. No, exit
  2. Yes, I accept
PANE
}

banner() {
  echo "remote-control is active" >> "$1"
}

echo "claude-remote-start.sh — spawn verification"

# --- the trust prompt is answered, and the session comes up -----------------
new_case autotrust
trust_prompt "$STATE/pane"
# Answering scrolls the prompt up rather than erasing it — the banner arrives
# with the prompt still in the scrollback capture-pane reads.
trust_prompt "$STATE/step1"; banner "$STATE/step1"
run_cmd start

check "answered trust prompt verifies"    '[ "$RC" -eq 0 ]'
check "session left running"              '[ -f "$STATE/session" ]'
check "picks 'Yes, I trust this folder'"  'grep -qx 1 "$STATE/keys"'
check "confirms with Enter"               'grep -qx Enter "$STATE/keys"'
check "says what it did"                  'grep -q "answering the workspace trust prompt" "$OUT"'

# --- the Bypass Permissions gate numbers its entries the other way around ---
# "1" here is "No, exit": answering this gate the way the trust prompt is
# answered would quit claude instead of accepting it.
new_case bypass
bypass_prompt "$STATE/pane"
bypass_prompt "$STATE/step1"; banner "$STATE/step1"
run_cmd start

check "answered bypass warning verifies" '[ "$RC" -eq 0 ]'
check "session left running"             '[ -f "$STATE/session" ]'
check "picks 'Yes, I accept', not 'No'"  '[ "$(head -n1 "$STATE/keys")" = 2 ]'
check "never sends the exit entry"       '! grep -qx 1 "$STATE/keys"'
check "says what it did"                 'grep -q "answering the Bypass Permissions warning" "$OUT"'

# --- both gates in a row, which is what a fresh machine actually shows ------
new_case both_gates
trust_prompt "$STATE/pane"
trust_prompt "$STATE/step1"; bypass_prompt "$STATE/step1"
cat "$STATE/step1" > "$STATE/step2"; banner "$STATE/step2"
run_cmd start

check "both gates get through"  '[ "$RC" -eq 0 ]'
check "trust answered first"    '[ "$(head -n1 "$STATE/keys")" = 1 ]'
check "bypass answered next"    'grep -qx 2 "$STATE/keys"'
check "one digit per gate"      '[ "$(grep -cx "[12]" "$STATE/keys")" -eq 2 ]'

# --- a dismissed prompt lingers in the scrollback and must not be re-answered
# Without a guard, every 5s pass would re-match the prompt text still sitting
# in the scrollback and type a stray digit into the live session.
new_case answered_once
trust_prompt "$STATE/pane"   # never becomes ready: verification runs its budget
run_cmd start

check "gives up when the banner never lands" '[ "$RC" -ne 0 ]'
check "recycles the session"                 '[ ! -f "$STATE/session" ]'
check "answers exactly once"                 '[ "$(grep -cx 1 "$STATE/keys")" -eq 1 ]'
check "sends exactly one Enter"              '[ "$(grep -cx Enter "$STATE/keys")" -eq 1 ]'

# --- opting out leaves the gates alone --------------------------------------
new_case no_autotrust
trust_prompt "$STATE/pane"
run_cmd start env CLAUDE_TMUX_AUTO_TRUST=0

check "opting out fails the spawn"      '[ "$RC" -ne 0 ]'
check "opting out sends no keys"        '[ ! -s "$STATE/keys" ]'
check "opting out recycles the session" '[ ! -f "$STATE/session" ]'
check "opting out explains the prompt"  'grep -q "waiting on the workspace trust prompt" "$OUT"'

# --- an unrelated failure still reports its own cause -----------------------
new_case logged_out
printf 'You must be logged in to use Claude Code\n' > "$STATE/pane"
run_cmd start

check "logged out is diagnosed"        'grep -q "not logged in" "$OUT"'
check "logged out sends no gate keys"  '[ ! -s "$STATE/keys" ]'
check "logged out notifies the user"   'grep -q "claude auth login" "$STATE/notify"'
check "logged out marks the state"     '[ -f "$(logout_mark)" ]'

# --- the logout notification fires once, not on every retry within a streak --
# notify_once is guarded so a persistent logout doesn't spam desktop alerts;
# the guard only clears once a spawn succeeds (log_reset). A single start goes
# through verify once, so this asserts the guard holds across that pass.
check "notifies exactly once"          '[ "$(wc -l < "$STATE/notify")" -eq 1 ]'

echo
echo "claude-remote-start.sh — status"

# --- status reads the startup output, not the whole scrollback --------------
# A live claude session can be asked about its own banner, putting the phrase
# in the scrollback. Checking everything would then report "registered" for a
# session that never registered at all.
new_case status_scrollback
: > "$STATE/session"
echo 500 > "$STATE/hist"
printf 'the banner to wait for is "remote-control is active"\n' > "$STATE/pane"
printf 'claude starting up\n' > "$STATE/head"
run_cmd status

check "mentioning the banner is not registering" '[ "$RC" -eq 1 ]'
check "reports NOT registered"                   'grep -q "NOT registered" "$OUT"'

new_case status_registered
: > "$STATE/session"
echo 500 > "$STATE/hist"
printf 'claude starting up\nremote-control is active\n' > "$STATE/head"
mkdir -p "$(dirname "$(logout_mark)")"; : > "$(logout_mark)"  # a stale marker from an earlier logout
run_cmd status

check "a real startup banner registers" '[ "$RC" -eq 0 ]'
check "reports registered"              'grep -q "running, registered" "$OUT"'
check "clears a stale logout marker"    '[ ! -f "$(logout_mark)" ]'

# --- a full history has dropped the banner, so absence proves nothing -------
new_case status_trimmed
: > "$STATE/session"
echo 2000 > "$STATE/hist"    # equals history_limit: oldest lines are gone
printf 'a long conversation\n' > "$STATE/head"
run_cmd status

check "trimmed history is not a failure" '[ "$RC" -eq 2 ]'
check "says registration is unconfirmed" 'grep -q "unconfirmed" "$OUT"'

new_case status_absent
run_cmd status

check "no session exits 1"     '[ "$RC" -eq 1 ]'
check "reports not running"    'grep -q "not running" "$OUT"'

# --- a recorded logout is surfaced by status, with the fix to hand -----------
new_case status_logged_out
mkdir -p "$(dirname "$(logout_mark)")"; : > "$(logout_mark)"
run_cmd status

check "logged-out status exits 1"    '[ "$RC" -eq 1 ]'
check "names the logout"             'grep -q "logged out" "$OUT"'
check "points at the login command"  'grep -q "claude auth login" "$OUT"'

rm -rf "$ROOT"
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
