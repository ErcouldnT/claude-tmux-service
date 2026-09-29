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
  : > "$STATE/screen"
  : > "$STATE/head"
  : > "$STATE/keys"
  : > "$STATE/cmd"
  echo 10   > "$STATE/hist"
  echo 2000 > "$STATE/limit"

  cat > "$STUBS/tmux" <<'STUB'
#!/bin/sh
cmd=$1
case "$cmd" in
  has-session)  [ -f "$STATE/session" ] ;;
  # $STATE/dies stands in for a claude that exits the moment it starts: the
  # session never comes to exist.
  new-session)  [ -f "$STATE/dies" ] || : > "$STATE/session"; printf '%s\n' "$*" >> "$STATE/cmd" ;;
  kill-session) rm -f "$STATE/session" ;;
  capture-pane)
    # Three shapes, told apart by argument count: -E is pane_head asking for
    # the opening history; a bare -p is pane_screen asking for the visible
    # screen; anything else is pane_text asking for the whole scrollback. A
    # case that never sets a screen gets the scrollback, which is what the
    # cases written before screens existed expect.
    if [ $# -ge 8 ]; then
      cat "$STATE/head"
    elif [ $# -le 4 ]; then
      if [ -s "$STATE/screen" ]; then cat "$STATE/screen"; else cat "$STATE/pane"; fi
    else
      cat "$STATE/pane"
    fi
    ;;
  display-message)
    # display-message -p -t <session> <format>
    case "$5" in
      '#{history_size}')  cat "$STATE/hist" ;;
      '#{history_limit}') cat "$STATE/limit" ;;
      # When the session was created; a session with no recorded birth was
      # born just now, so it is never old enough to refresh.
      '#{session_created}') cat "$STATE/created" 2>/dev/null || date +%s ;;
      *) echo "stub tmux: unexpected format: $5" >&2; exit 64 ;;
    esac
    ;;
  send-keys)
    # send-keys -t <session> [-l] <key>. The -l form is how the login
    # walkthrough pastes the code, which carries a '#' tmux would otherwise
    # read as a format string; record the code itself, not the flag. A pasted
    # code standing in for an accepted one is what flips the stub account to
    # signed-in below.
    if [ "$4" = -l ]; then key=$5; : > "$STATE/code_sent"; else key=$4; fi
    printf '%s\n' "$key" >> "$STATE/keys"
    # Digits advance as well as Enter: claude's menus act on the number key
    # alone, which is the whole reason answer_gate has to check afterwards
    # whether the gate is still up before confirming.
    case "$key" in
      Enter|[0-9])
        n=$(cat "$STATE/step" 2>/dev/null || echo 0)
        n=$((n + 1))
        if [ -f "$STATE/step$n" ]; then
          cat "$STATE/step$n" > "$STATE/pane"
          # screenN is what is left on screen after that advance; without one
          # the screen just follows the scrollback.
          if [ -f "$STATE/screen$n" ]; then cat "$STATE/screen$n" > "$STATE/screen"; fi
          echo "$n" > "$STATE/step"
        fi
        ;;
    esac
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

# Same as run_cmd, but feeds $1 on stdin: the login walkthrough asks for the
# sign-in code that way.
run_cmd_in() {
  input=$1; cmd=$2; shift 2
  HOME="$HOME_DIR" STATE="$STATE" CLAUDE_TMUX_SESSION=test \
    XDG_CONFIG_HOME="$HOME_DIR/.config" \
    XDG_STATE_HOME="$HOME_DIR/.local/state" \
    "$@" sh "$REPO/claude-remote-start.sh" "$cmd" >"$OUT" 2>&1 <<INPUT
$input
INPUT
  RC=$?
}

# The default claude stub only has to exist. This one answers `auth status`,
# which is how the script tells a live claude.ai session from a lapsed one —
# signed out until a code is pasted, signed in afterwards.
auth_stub() {
  cat > "$STUBS/claude" <<'STUB'
#!/bin/sh
if [ "$1" = auth ] && [ "$2" = status ]; then
  if [ -f "$STATE/code_sent" ]; then
    echo '{"loggedIn": true, "subscriptionType": "pro"}'
  else
    echo '{"loggedIn": false, "authMethod": "none"}'
  fi
fi
:
STUB
  chmod +x "$STUBS/claude"
}

# auth_stub, already signed in.
signed_in() { auth_stub; : > "$STATE/code_sent"; }

# Backdate file $2 by $1 seconds. GNU date, then BSD: these tests run on macOS too.
age_file() {
  _ts=$(date -d "@$(( $(date +%s) - $1 ))" +%Y%m%d%H%M.%S 2>/dev/null ||
        date -r "$(( $(date +%s) - $1 ))" +%Y%m%d%H%M.%S 2>/dev/null)
  touch -t "$_ts" "$2"
}
transcript_file() { echo "$HOME_DIR/.claude/projects/-home-tester/$1.jsonl"; }
born_ago() { echo "$(( $(date +%s) - $1 ))" > "$STATE/created"; }
# claude's bar when idle, and when working on something.
idle_bar() { printf '  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on \xc2\xb7 1 shell\n' >> "$1"; }
busy_bar() { printf '  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle) \xc2\xb7 esc to interrupt\n' >> "$1"; }

abandoned() { cat "$HOME_DIR/.local/state/claude-tmux/abandoned-sessions" 2>/dev/null; }
hook_file() { echo "$HOME_DIR/.local/state/claude-tmux/hooks.json"; }

# A machine that finished onboarding long ago. The flag is written once and
# never cleared, which is the trap: it says nothing about the token.
mark_onboarded() {
  echo '{"hasCompletedOnboarding": true}' > "$HOME_DIR/.claude.json"
}

# Where mark_logged_out drops its marker, given the XDG_STATE_HOME above.
logout_mark() { echo "$HOME_DIR/.local/state/claude-tmux/logged-out"; }

# The pinned conversation: where its id is recorded, and the transcript claude
# would have written for it. The directory under projects/ is named after the
# working directory; the script globs for it, so any name will do here.
id_file()    { echo "$HOME_DIR/.local/state/claude-tmux/session-id"; }
saved_id()   { cat "$(id_file)" 2>/dev/null; }
pin_id() {
  mkdir -p "$(dirname "$(id_file)")"
  echo "$1" > "$(id_file)"
}
write_transcript() {
  mkdir -p "$HOME_DIR/.claude/projects/-home-tester"
  : > "$HOME_DIR/.claude/projects/-home-tester/$1.jsonl"
}
# The flags claude was actually launched with.
spawn_cmd() { cat "$STATE/cmd" 2>/dev/null; }

# Each writes its screen to the file named by $1, so a case can build up the
# scrollback the way claude does: a dismissed prompt scrolls up, it does not
# disappear.
theme_prompt() {
  cat >> "$1" <<'PANE'
Welcome to Claude Code v2.1.227
Let's get started.
Choose the text style that looks best with your terminal
To change this later, run /theme
  1. Auto (match terminal)
> 2. Dark mode
  3. Light mode
PANE
}

trust_prompt() {
  cat >> "$1" <<'PANE'
Accessing workspace:
/Users/ercode
Quick safety check: Is this a project you created or one you trust?
> 1. Yes, I trust this folder
  2. No, exit
PANE
}

# The same prompt as claude renders it now: no numbers, and "No, exit" first.
trust_prompt_unnumbered() {
  cat >> "$1" <<'PANE'
Accessing workspace:
/Users/ercode
Quick safety check: Is this a project you created or one you trust?
❯ No, exit
  Yes, I trust this folder
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

signin_prompt() {
  cat >> "$1" <<'PANE'
Claude Code can be used with your Claude subscription or billed based on API
Select login method:
> 1. Claude account with subscription
  2. Anthropic Console account
PANE
}

# Not a first-run prompt: claude raises this one when the conversation being
# resumed has grown large, so a long-lived pinned session meets it repeatedly.
# Note what it does to the bottom of the screen — it covers the status bar the
# registration check reads.
resume_prompt() {
  cat >> "$1" <<'PANE'
This session is 1d 5h old and 210.6k tokens.
Resuming the full session will consume a substantial portion of your usage
limits. We recommend resuming from a summary.
> 1. Resume from summary (recommended)
  2. Resume full session as-is
  3. Don't ask me again
Enter to confirm · Esc to cancel
PANE
}

# The status bar claude paints at the bottom of the pane. This, not the
# banner, is what the script reads to decide whether the session is registered
# right now — so a case that wants a healthy session has to render it.
status_bar() {
  printf '%s\n' "  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle)             /rc" >> "$1"
}

# The same bar, as it reads when Remote Control could not register.
status_bar_failed() {
  printf '%s\n' "  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle)      /rc failed" >> "$1"
}

banner() {
  echo "remote-control is active" >> "$1"
  status_bar "$1"
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
check "is already on 'Yes, I trust this folder'" '! grep -qxE "Up|Down" "$STATE/keys"'
check "confirms with Enter"               'grep -qx Enter "$STATE/keys"'
check "sends no digit"                    '! grep -qxE "[0-9]" "$STATE/keys"'
check "says what it did"                  'grep -q "answering the workspace trust prompt" "$OUT"'

# --- the layout that broke this on a real machine ---------------------------
# Claude Code dropped the numbers from this menu and opened it on "No, exit".
# A digit is ignored there, and the Enter behind it confirmed the exit: claude
# died ten seconds after every spawn, and the watchdog respawned it into the
# same trap. Navigating to the entry by its text is what survives both layouts.
new_case trust_reordered
trust_prompt_unnumbered "$STATE/pane"
trust_prompt_unnumbered "$STATE/step1"; banner "$STATE/step1"
run_cmd start

check "the reordered prompt verifies"     '[ "$RC" -eq 0 ]'
check "session left running"              '[ -f "$STATE/session" ]'
check "moves onto the trust entry"        '[ "$(sed -n 1p "$STATE/keys")" = Down ]'
check "then confirms it"                  '[ "$(sed -n 2p "$STATE/keys")" = Enter ]'
check "never confirms 'No, exit'"         '[ "$(grep -cx Enter "$STATE/keys")" -eq 1 ]'

# --- an entry the script cannot find is reported, not guessed at ------------
# Pressing Enter on an unrecognised menu would answer whatever is highlighted,
# and on both of these menus that is the one that quits.
new_case trust_reworded
printf 'Quick safety check: do you trust this folder?\n\u276f No, exit\n  Sure, go ahead\n' > "$STATE/pane"
run_cmd start

check "a reworded menu fails the spawn"   '[ "$RC" -ne 0 ]'
check "and nothing is confirmed"          '! grep -qx Enter "$STATE/keys"'
check "the session is recycled"           '[ ! -f "$STATE/session" ]'
check "the log names the missing entry"   'grep -q "could not find an entry matching" "$OUT"'

# --- the Bypass Permissions gate numbers its entries the other way around ---
# "1" here is "No, exit": answering this gate the way the trust prompt is
# answered would quit claude instead of accepting it.
new_case bypass
bypass_prompt "$STATE/pane"
bypass_prompt "$STATE/step1"; banner "$STATE/step1"
run_cmd start

check "answered bypass warning verifies" '[ "$RC" -eq 0 ]'
check "session left running"             '[ -f "$STATE/session" ]'
check "moves onto 'Yes, I accept'"       '[ "$(sed -n 1p "$STATE/keys")" = Down ]'
check "never confirms 'No, exit'"        '[ "$(sed -n 1p "$STATE/keys")" != Enter ]'
check "says what it did"                 'grep -q "answering the Bypass Permissions warning" "$OUT"'

# --- the resume chooser is answered, and the session comes up ---------------
new_case resume_gate
resume_prompt "$STATE/screen"
# The chooser already sits on the entry we want, so Enter alone answers it.
banner "$STATE/step1"; banner "$STATE/screen1"
run_cmd start

check "the resume prompt verifies"      '[ "$RC" -eq 0 ]'
check "session left running"            '[ -f "$STATE/session" ]'
check "picks 'Resume from summary'"     '[ "$(sed -n 1p "$STATE/keys")" = Enter ]'
check "and confirms it exactly once"    '[ "$(grep -cx Enter "$STATE/keys")" -eq 1 ]'
check "says what it did"                'grep -q "answering the resume prompt" "$OUT"'

# --- the sign-in screen needs a person, so the watchdog must not sit on it --
new_case signin
signin_prompt "$STATE/pane"
run_cmd start

check "sign-in fails the spawn"      '[ "$RC" -eq 1 ]'
check "sign-in sends no gate keys"   '[ ! -s "$STATE/keys" ]'
check "sign-in recycles the session" '[ ! -f "$STATE/session" ]'
check "points at the login command"  'grep -q "login" "$OUT"'
check "sign-in marks the state"      '[ -f "$(logout_mark)" ]'
check "sign-in notifies the user"    'grep -q "sign-in" "$STATE/notify"'

# --- the theme picker, which a brand-new install opens on -------------------
new_case theme
theme_prompt "$STATE/pane"
theme_prompt "$STATE/step1"; banner "$STATE/step1"
run_cmd start

check "answered theme picker verifies"   '[ "$RC" -eq 0 ]'
check "session left running"             '[ -f "$STATE/session" ]'
check "moves up to 'Auto (match terminal)'" '[ "$(sed -n 1p "$STATE/keys")" = Up ]'
check "then confirms it"                 '[ "$(sed -n 2p "$STATE/keys")" = Enter ]'
check "says what it did"                 'grep -q "answering the theme picker" "$OUT"'

# --- all three gates in a row, which is what a fresh machine actually shows -
# The scrollback accumulates, so every gate stays matchable there, while the
# screen shows only the gate currently up — which is why the entry is located
# on the screen and never in the scrollback. Each gate takes the arrows it
# needs to reach its entry and exactly one Enter to confirm it, and the three
# gates disagree about where that entry sits: above, on, and below the cursor.
new_case all_gates
theme_prompt "$STATE/pane"
theme_prompt "$STATE/screen"
theme_prompt "$STATE/step1"; trust_prompt "$STATE/step1"
trust_prompt "$STATE/screen1"
cat "$STATE/step1" > "$STATE/step2"; bypass_prompt "$STATE/step2"
bypass_prompt "$STATE/screen2"
cat "$STATE/step2" > "$STATE/step3"; banner "$STATE/step3"
banner "$STATE/screen3"
run_cmd start

check "every gate gets through" '[ "$RC" -eq 0 ]'
check "theme reaches up for Auto"  '[ "$(sed -n 1p "$STATE/keys")" = Up ]'
check "theme is confirmed"        '[ "$(sed -n 2p "$STATE/keys")" = Enter ]'
check "trust confirms in place"   '[ "$(sed -n 3p "$STATE/keys")" = Enter ]'
check "bypass steps off 'No'"     '[ "$(sed -n 4p "$STATE/keys")" = Down ]'
check "bypass is confirmed"       '[ "$(sed -n 5p "$STATE/keys")" = Enter ]'
check "one Enter per gate"        '[ "$(grep -cx Enter "$STATE/keys")" -eq 3 ]'

# --- a dismissed prompt lingers in the scrollback and must not be re-answered
# Without a guard, every 5s pass would re-match the prompt text still sitting
# in the scrollback and type a stray digit into the live session.
new_case answered_once
trust_prompt "$STATE/pane"   # never becomes ready: verification runs its budget
run_cmd start

check "gives up when the banner never lands" '[ "$RC" -ne 0 ]'
check "recycles the session"                 '[ ! -f "$STATE/session" ]'
check "answers exactly once"                 '[ "$(wc -l < "$STATE/keys")" -eq 1 ]'
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
echo "claude-remote-start.sh — conversation continuity"

# --- the first spawn names the conversation, so later ones can find it ------
# Letting claude pick the id and reading it back afterwards would leave nothing
# to reattach to; naming it up front is the whole mechanism.
new_case resume_first
banner "$STATE/pane"
run_cmd start

check "first spawn verifies"           '[ "$RC" -eq 0 ]'
check "first spawn names the session"  'spawn_cmd | grep -q -- "--session-id"'
check "first spawn does not resume"    '! spawn_cmd | grep -q -- "--resume"'
check "the id is recorded"             '[ -n "$(saved_id)" ]'
check "the recorded id was the one used" 'spawn_cmd | grep -q -- "--session-id $(saved_id)"'

# --- a restart reattaches to that same conversation -------------------------
new_case resume_again
banner "$STATE/pane"
pin_id 11111111-2222-3333-4444-555555555555
write_transcript 11111111-2222-3333-4444-555555555555
run_cmd start

check "restart verifies"             '[ "$RC" -eq 0 ]'
check "restart resumes the pinned id" 'spawn_cmd | grep -q -- "--resume 11111111-2222-3333-4444-555555555555"'
check "restart names no new session"  '! spawn_cmd | grep -q -- "--session-id"'
check "the id survives the restart"   '[ "$(saved_id)" = 11111111-2222-3333-4444-555555555555 ]'

# --- an id with no transcript behind it is not worth resuming ---------------
# claude would exit instantly on --resume; this is the state left behind when a
# first spawn recorded an id but never got far enough to write anything.
new_case resume_no_transcript
banner "$STATE/pane"
pin_id 11111111-2222-3333-4444-555555555555
run_cmd start

check "a transcript-less id is dropped" '! spawn_cmd | grep -q -- "--resume"'
check "a fresh conversation is named"   'spawn_cmd | grep -q -- "--session-id"'
check "the recorded id is replaced"     '[ "$(saved_id)" != 11111111-2222-3333-4444-555555555555 ]'

# --- a junk id file is ignored rather than spliced onto the command line ----
new_case resume_junk_id
banner "$STATE/pane"
pin_id "; rm -rf /"
run_cmd start

check "junk is not passed to claude" '! spawn_cmd | grep -q "rm -rf"'
check "junk is replaced by a real id" 'spawn_cmd | grep -q -- "--session-id"'

# --- opting out starts every session empty ----------------------------------
new_case resume_off
banner "$STATE/pane"
pin_id 11111111-2222-3333-4444-555555555555
write_transcript 11111111-2222-3333-4444-555555555555
run_cmd start env CLAUDE_TMUX_RESUME=0

check "opting out does not resume"    '! spawn_cmd | grep -q -- "--resume"'
check "opting out pins nothing"       '! spawn_cmd | grep -q -- "--session-id"'

# --- a conversation that keeps failing to start is eventually abandoned -----
# Only a failure the transcript could have caused counts toward that: claude
# dying straight after start while signed in. Three in a row, and the watchdog
# stops resuming it — otherwise a transcript claude cannot open wedges the
# service forever.
new_case resume_gives_up
signed_in
: > "$STATE/dies"
pin_id 11111111-2222-3333-4444-555555555555
write_transcript 11111111-2222-3333-4444-555555555555
run_cmd start
check "one failure keeps the conversation"  '[ "$(saved_id)" = 11111111-2222-3333-4444-555555555555 ]'
run_cmd start
check "two failures keep it too"            '[ "$(saved_id)" = 11111111-2222-3333-4444-555555555555 ]'
run_cmd start
check "the third gives up on it"            '[ -z "$(saved_id)" ]'
check "and says so"                         'grep -q "starting a new one" "$OUT"'
check "the id is archived, not lost"        'abandoned | grep -q 11111111-2222-3333-4444-555555555555'
check "and the way back is logged"          'grep -q "claude --resume 11111111-2222-3333-4444-555555555555" "$OUT"'

# --- failures that are not the transcript's never cost the conversation -----
# The regression behind this: a trust prompt the watchdog could not answer
# failed three spawns in a row, and those three were charged to the
# conversation, which was dropped. Nothing about it was wrong.
new_case resume_kept_when_never_ready
signed_in
pin_id 11111111-2222-3333-4444-555555555555
write_transcript 11111111-2222-3333-4444-555555555555
run_cmd start; run_cmd start; run_cmd start; run_cmd start
check "four banner-less spawns keep the conversation" '[ "$(saved_id)" = 11111111-2222-3333-4444-555555555555 ]'
check "and charge nothing to it" '[ ! -f "$HOME_DIR/.local/state/claude-tmux/resume-failures" ]'

# A fast exit while signed out is a logout, whatever is being resumed.
new_case resume_kept_when_logged_out
auth_stub
: > "$STATE/dies"
pin_id 11111111-2222-3333-4444-555555555555
write_transcript 11111111-2222-3333-4444-555555555555
run_cmd start; run_cmd start; run_cmd start; run_cmd start
check "exits while signed out keep the conversation" '[ "$(saved_id)" = 11111111-2222-3333-4444-555555555555 ]'

# --- claude rejecting the transcript is not worth three passes --------------
new_case resume_rejected
printf 'No conversation found with session ID\n' > "$STATE/pane"
pin_id 11111111-2222-3333-4444-555555555555
write_transcript 11111111-2222-3333-4444-555555555555
run_cmd start

check "a rejected transcript fails the spawn" '[ "$RC" -ne 0 ]'
check "and is dropped immediately"            '[ -z "$(saved_id)" ]'
check "and recycles the session"              '[ ! -f "$STATE/session" ]'
# Dropping the conversation ends the matter: the same spawn's failure must not
# also be charged to the counter, or the next conversation starts one down.
check "and leaves no failure charged"         '[ ! -f "$HOME_DIR/.local/state/claude-tmux/resume-failures" ]'

# --- a success clears the failure count -------------------------------------
# Without this, three failures spread over a week would abandon a conversation
# that has been working fine in between.
new_case resume_fail_count_clears
signed_in
pin_id 11111111-2222-3333-4444-555555555555
write_transcript 11111111-2222-3333-4444-555555555555
: > "$STATE/dies"
run_cmd start                       # fails: claude exits
rm -f "$STATE/dies"; banner "$STATE/pane"
run_cmd start                       # succeeds, clearing the count
rm -f "$STATE/session"; : > "$STATE/pane"; : > "$STATE/dies"
run_cmd start                       # fails again — but as the first, not the second
run_cmd start                       # the second
check "a working conversation is kept" '[ "$(saved_id)" = 11111111-2222-3333-4444-555555555555 ]'

# --- stop keeps the thread, reset drops it ----------------------------------
new_case resume_stop_vs_reset
pin_id 11111111-2222-3333-4444-555555555555
: > "$STATE/session"
run_cmd stop

check "stop leaves the session dead"  '[ ! -f "$STATE/session" ]'
check "stop keeps the conversation"   '[ "$(saved_id)" = 11111111-2222-3333-4444-555555555555 ]'

: > "$STATE/session"
run_cmd reset

check "reset kills the session"       '[ ! -f "$STATE/session" ]'
check "reset forgets the conversation" '[ -z "$(saved_id)" ]'
check "reset says what it did"        'grep -q "starts empty" "$OUT"'

# --- each spawn carries the hook that reports the live conversation --------
new_case hook_on_spawn
banner "$STATE/pane"
run_cmd start
check "spawn passes --settings"        'spawn_cmd | grep -q -- "--settings $(hook_file)"'
check "the settings are valid JSON"    'python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$(hook_file)"'
check "they register a SessionStart hook" 'grep -q SessionStart "$(hook_file)"'
check "which calls back into record-session" 'grep -q "record-session" "$(hook_file)"'
check "naming the id file it writes"   'grep -q "$(id_file)" "$(hook_file)"'

new_case hook_off_without_resume
banner "$STATE/pane"
run_cmd start env CLAUDE_TMUX_RESUME=0
check "no resume, no hook"             '! spawn_cmd | grep -q -- "--settings"'

# --- the hook records the id it is given -------------------------------------
new_case record_session
pin_id 11111111-2222-3333-4444-555555555555
echo 2 > "$HOME_DIR/.local/state/claude-tmux/resume-failures"
run_cmd_in '{"session_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","source":"clear"}' record-session
check "exits 0"                        '[ "$RC" -eq 0 ]'
check "records the new conversation"   '[ "$(saved_id)" = aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee ]'
check "prints nothing (it would land in the conversation)" '[ ! -s "$OUT" ]'
check "a new conversation starts with no failures charged" '[ ! -f "$HOME_DIR/.local/state/claude-tmux/resume-failures" ]'

new_case record_session_junk
pin_id 11111111-2222-3333-4444-555555555555
run_cmd_in '{"session_id":"$(rm -rf /)","source":"clear"}' record-session
check "junk is ignored"                '[ "$(saved_id)" = 11111111-2222-3333-4444-555555555555 ]'
check "and still exits 0"              '[ "$RC" -eq 0 ]'
run_cmd_in 'not json at all' record-session
check "so is a payload with no id"     '[ "$(saved_id)" = 11111111-2222-3333-4444-555555555555 ]'

# --- after a /clear, the next restart comes back to the new conversation ----
# The bug this exists for: the id was pinned once at spawn, a /clear from the
# phone moved claude to a new conversation, and every restart after that
# resumed the old one.
new_case follows_clear
pin_id 11111111-2222-3333-4444-555555555555
write_transcript 11111111-2222-3333-4444-555555555555
run_cmd_in '{"session_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","source":"clear"}' record-session
write_transcript aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
banner "$STATE/pane"
run_cmd start
check "resumes the post-/clear conversation" 'spawn_cmd | grep -q -- "--resume aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"'
check "not the one before it"          '! spawn_cmd | grep -q 11111111-2222-3333-4444-555555555555'

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

# --- a replayed transcript is not evidence of anything ----------------------
# The bug this guards: --resume replays the previous conversation into the
# pane, and a conversation that ever discussed Remote Control contains the
# banner verbatim. Reading the scrollback then "verifies" a session whose own
# status bar says the registration failed.
new_case verify_replayed_banner
echo 500 > "$STATE/hist"
{
  echo "so the pane will contain remote-control is active from the replay"
  echo "and a Remote Control disconnected line further down"
} > "$STATE/pane"
printf 'the tail of that replay\n' > "$STATE/screen"
status_bar_failed "$STATE/screen"
run_cmd start

check "a replayed banner does not verify"  '[ "$RC" -ne 0 ]'
check "the session is recycled"            '[ ! -f "$STATE/session" ]'
check "the log names the real cause"       'grep -q "registration failed" "$OUT"'
check "and points at the token"            'grep -q "expired claude.ai token" "$OUT"'

# --- the status bar outranks a missing banner -------------------------------
# The mirror-image bug: on a resumed session the replay pushes the real banner
# out of the opening output, so checking only there reports a healthy session
# as unregistered.
new_case status_bar_registered
: > "$STATE/session"
echo 500 > "$STATE/hist"
printf 'replayed transcript, no banner in the opening output\n' > "$STATE/head"
printf 'some conversation\n' > "$STATE/screen"
status_bar "$STATE/screen"
run_cmd status

check "a live status bar registers"  '[ "$RC" -eq 0 ]'
check "reports registered"           'grep -q "running, registered" "$OUT"'

new_case status_bar_failed
: > "$STATE/session"
echo 500 > "$STATE/hist"
printf 'remote-control is active\n' > "$STATE/head"   # stale: it did register once
printf 'some conversation\n' > "$STATE/screen"
status_bar_failed "$STATE/screen"
run_cmd status

check "a failed status bar outranks a stale banner" '[ "$RC" -eq 1 ]'
check "status names the failed registration"        'grep -q "registration FAILED" "$OUT"'

# --- a Claude Code that does not show its registration at all --------------
new_case status_chrome_only
: > "$STATE/session"
echo 0 > "$STATE/hist"
printf 'a long conversation\n' > "$STATE/screen"
printf '  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on \xc2\xb7 1 shell \xc2\xb7 \xe2\x86\x90 for agents\n' >> "$STATE/screen"
: > "$STATE/head"
run_cmd status
check "reports unconfirmed, not failed" '[ "$RC" -eq 2 ]'
check "and says why"                    'grep -q "not shown by this Claude Code" "$OUT"'

echo
echo "claude-remote-start.sh — health checks on a running session"

# --- a session that lost its registration is recycled -----------------------
new_case health_recycles
: > "$STATE/session"
printf 'a long conversation\n' > "$STATE/screen"
status_bar_failed "$STATE/screen"
run_cmd start env CLAUDE_TMUX_HEALTH=1 CLAUDE_TMUX_HEALTH_STRIKES=1

check "an unregistered session is recycled" '[ ! -f "$STATE/session" ]'
check "and the pass reports failure"        '[ "$RC" -ne 0 ]'
check "the log says why"                    'grep -q "unregistered" "$OUT"'

# --- one bad reading is not enough ------------------------------------------
# A reconnect in progress reads as failed too, so the default is to look twice.
new_case health_strikes
: > "$STATE/session"
printf 'a long conversation\n' > "$STATE/screen"
status_bar_failed "$STATE/screen"
run_cmd start env CLAUDE_TMUX_HEALTH=1 CLAUDE_TMUX_HEALTH_STRIKES=2

check "one failed check does not recycle" '[ -f "$STATE/session" ]'
check "the pass still succeeds"           '[ "$RC" -eq 0 ]'
check "but it is announced"               'grep -q "re-checking" "$OUT"'

# --- a healthy session is left alone -----------------------------------------
new_case health_leaves_healthy
: > "$STATE/session"
printf 'a long conversation\n' > "$STATE/screen"
status_bar "$STATE/screen"
run_cmd start env CLAUDE_TMUX_HEALTH=1 CLAUDE_TMUX_HEALTH_STRIKES=1

check "a registered session survives" '[ -f "$STATE/session" ]'
check "and nothing is logged"         '[ ! -s "$OUT" ]'

# --- the resume chooser can appear on a session that has been up for days ----
# The reconnect after a dropped registration resumes the pinned conversation,
# and a large one is met with the chooser. Answering it costs nothing; letting
# it sit costs the machine, because it covers the bar the check reads.
new_case health_answers_resume_gate
: > "$STATE/session"
resume_prompt "$STATE/screen"
banner "$STATE/step1"; banner "$STATE/screen1"
run_cmd start env CLAUDE_TMUX_HEALTH=1 CLAUDE_TMUX_HEALTH_STRIKES=1

check "the gate is answered, not recycled" '[ -f "$STATE/session" ]'
check "picks 'Resume from summary'"        '[ "$(sed -n 1p "$STATE/keys")" = Enter ]'
check "and the pass succeeds"              '[ "$RC" -eq 0 ]'

# --- the chooser is read off the screen, never the scrollback ----------------
# This session is itself a claude that can be asked about its own resume
# prompt, so the phrase turns up in transcripts that are not prompts at all.
new_case health_resume_gate_scrollback
: > "$STATE/session"
printf 'we talked about the "Resume from summary" prompt yesterday\n' > "$STATE/pane"
printf 'an ordinary conversation\n' > "$STATE/screen"
status_bar "$STATE/screen"
run_cmd start env CLAUDE_TMUX_HEALTH=1 CLAUDE_TMUX_HEALTH_STRIKES=1

check "a transcript mentioning it is not a prompt" '[ ! -s "$STATE/keys" ]'
check "the session is left alone"                  '[ -f "$STATE/session" ]'

# --- an unreadable state is not a failure ------------------------------------
# No status bar and no banner means the script cannot tell, and killing a
# working session over that is worse than leaving it be — for a while. The
# default leash is CLAUDE_TMUX_UNKNOWN_STRIKES checks long, so one is tolerated.
new_case health_unknown_left_alone
: > "$STATE/session"
printf 'no chrome this version renders differently\n' > "$STATE/screen"
printf 'nothing conclusive here either\n' > "$STATE/head"
run_cmd start env CLAUDE_TMUX_HEALTH=1 CLAUDE_TMUX_HEALTH_STRIKES=1

check "an unknown state survives" '[ -f "$STATE/session" ]'

# --- but "unknown" cannot mean "healthy" forever -----------------------------
# A session wedged behind a prompt this script does not recognise reads unknown
# on every check. Leaving that alone indefinitely is what kept one offline for
# two days, so the tolerance runs out and the session is recycled.
new_case health_unknown_eventually_recycled
: > "$STATE/session"
printf 'a full-screen prompt no version of this script has heard of\n' > "$STATE/screen"
printf 'nothing conclusive here either\n' > "$STATE/head"
run_cmd start env CLAUDE_TMUX_HEALTH=1 CLAUDE_TMUX_UNKNOWN_STRIKES=1

check "a session stuck on unknown is recycled" '[ ! -f "$STATE/session" ]'
check "and the pass reports failure"           '[ "$RC" -ne 0 ]'
check "the log says the bar is unreadable"     'grep -q "without a readable" "$OUT"'
check "the user is told"                       'grep -q "stopped reporting its status" "$STATE/notify"'

# --- a working session is not recycled for hiding its registration ----------
# Current Claude Code shows no "/rc" at all, and draws on the alternate screen,
# so the banner is gone once it scrolls. A session busy for half an hour was
# recycled mid-task for that. Its own prompt chrome on screen says nothing is
# covering it, which is what the unknown strikes are really about.
new_case health_unknown_with_chrome
: > "$STATE/session"
printf 'working on something long\n' > "$STATE/screen"
printf '  \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle) \xc2\xb7 esc to interrupt\n' >> "$STATE/screen"
: > "$STATE/head"
run_cmd start env CLAUDE_TMUX_HEALTH=1 CLAUDE_TMUX_UNKNOWN_STRIKES=1
check "a busy session with its chrome up survives" '[ -f "$STATE/session" ]'
check "and nothing is logged"                      '[ ! -s "$OUT" ]'

# --- an old, idle session is refreshed ---------------------------------------
# The registration can drop silently and nothing on screen says so any more;
# a fresh start renews it. Old enough and idle enough, the session is
# restarted — and comes back in the same conversation.
X=11111111-2222-3333-4444-555555555555
refresh_setup() {
  : > "$STATE/session"
  pin_id $X
  write_transcript $X
  printf 'an ordinary conversation\n' > "$STATE/screen"
  idle_bar "$STATE/screen"
  born_ago 25200                            # up 7h
  age_file 7200 "$(transcript_file $X)"     # last written 2h ago
}

new_case refresh_idle_old
refresh_setup
run_cmd start env CLAUDE_TMUX_HEALTH=1
check "an old idle session is restarted"  '[ ! -f "$STATE/session" ]'
check "the pass reports it, so the loop waits" '[ "$RC" -ne 0 ]'
check "the log says why"                  'grep -q "refreshing session" "$OUT"'
check "with its age and idle time"        'grep -q "up 7h, idle 120m" "$OUT"'
check "the conversation is kept"          '[ "$(saved_id)" = $X ]'
banner "$STATE/pane"
run_cmd start
check "and the respawn resumes it"        'spawn_cmd | grep -q -- "--resume $X"'

new_case refresh_not_when_active
refresh_setup
touch "$(transcript_file $X)"             # written just now
run_cmd start env CLAUDE_TMUX_HEALTH=1
check "a session in use is left alone"    '[ -f "$STATE/session" ]'

new_case refresh_not_when_young
refresh_setup
born_ago 3600                             # up 1h
run_cmd start env CLAUDE_TMUX_HEALTH=1
check "a young session is left alone"     '[ -f "$STATE/session" ]'

# A long tool call writes nothing to the transcript until it returns, so the
# transcript alone would call it idle. claude's own bar says otherwise.
new_case refresh_not_when_busy
refresh_setup
printf 'running a long build\n' > "$STATE/screen"
busy_bar "$STATE/screen"
run_cmd start env CLAUDE_TMUX_HEALTH=1
check "a busy session is left alone"      '[ -f "$STATE/session" ]'

new_case refresh_not_without_resume
refresh_setup
run_cmd start env CLAUDE_TMUX_HEALTH=1 CLAUDE_TMUX_RESUME=0
check "with nothing to resume, no refresh" '[ -f "$STATE/session" ]'

new_case refresh_disabled
refresh_setup
run_cmd start env CLAUDE_TMUX_HEALTH=1 CLAUDE_TMUX_REFRESH_AGE=0
check "CLAUDE_TMUX_REFRESH_AGE=0 disables it" '[ -f "$STATE/session" ]'

# --- that tolerance can be switched off too ----------------------------------
new_case health_unknown_disabled
: > "$STATE/session"
printf 'a full-screen prompt no version of this script has heard of\n' > "$STATE/screen"
printf 'nothing conclusive here either\n' > "$STATE/head"
run_cmd start env CLAUDE_TMUX_HEALTH=1 CLAUDE_TMUX_UNKNOWN_STRIKES=0

check "CLAUDE_TMUX_UNKNOWN_STRIKES=0 leaves it be" '[ -f "$STATE/session" ]'

# --- health checks can be switched off ---------------------------------------
new_case health_disabled
: > "$STATE/session"
printf 'a long conversation\n' > "$STATE/screen"
status_bar_failed "$STATE/screen"
run_cmd start env CLAUDE_TMUX_HEALTH=0

check "CLAUDE_TMUX_HEALTH=0 disables recycling" '[ -f "$STATE/session" ]'

echo
echo "claude-remote-start.sh — the login walkthrough"

# --- an onboarded box with a lapsed token still has to sign in ---------------
# hasCompletedOnboarding is written once and stays true forever, so reading it
# as "signed in" made this command a no-op on the only machine that needs it:
# one that onboarded months ago and has since had its token expire.
new_case login_onboarded_but_logged_out
mark_onboarded
auth_stub
run_cmd_in "" login env CLAUDE_TMUX_LOGIN_WAIT=6

check "onboarding alone is not a sign-in"  '! grep -qE "Signed in|Setup complete" "$OUT"'
check "and the command reports failure"    '[ "$RC" -ne 0 ]'
check "it asks claude to sign in"          'grep -q "claude auth login" "$STATE/cmd"'
check "not the plain first-run TUI"        '! grep -q "remote-control" "$STATE/cmd"'

# --- the code is relayed, and the URL survives its prefix --------------------
# `claude auth login` prints the URL behind "If the browser didn't open,
# visit: ", so a check anchored at the start of the line never finds it.
new_case login_relays_the_code
mark_onboarded
auth_stub
cat > "$STATE/pane" <<'PANE'
Opening browser to sign in…
If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&state=abc123
Paste code here if prompted >
PANE
cp "$STATE/pane" "$STATE/screen"
run_cmd_in 'theCode#abc123' login env CLAUDE_TMUX_LOGIN_WAIT=30

check "the sign-in is reported"        'grep -q "Signed in" "$OUT"'
check "and the command succeeds"       '[ "$RC" -eq 0 ]'
check "the prefixed URL is found"      'grep -q "https://claude.com/cai/oauth/authorize" "$OUT"'
check "the prefix is left behind"      '! grep -q "browser didn.t open" "$OUT"'
check "the code is pasted verbatim"    'grep -qx "theCode#abc123" "$STATE/keys"'
check "the logout marker is cleared"   '[ ! -f "$(logout_mark)" ]'

# --- a box that is already signed in has nothing to do -----------------------
new_case login_already_signed_in
mark_onboarded
auth_stub
: > "$STATE/code_sent"
run_cmd_in "" login env CLAUDE_TMUX_LOGIN_WAIT=6

check "an existing sign-in is recognised" '[ "$RC" -eq 0 ]'
check "and nothing is pasted"             '[ ! -s "$STATE/keys" ]'

# --- a brand-new machine still gets the first-run walk -----------------------
new_case login_fresh_machine
auth_stub
run_cmd_in "" login env CLAUDE_TMUX_LOGIN_WAIT=6

check "an un-onboarded box walks the TUI" '! grep -q "auth login" "$STATE/cmd"'
check "and says so"                       'grep -q "first-run setup" "$OUT"'

rm -rf "$ROOT"
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
