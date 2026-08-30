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
  new-session)  : > "$STATE/session"; printf '%s\n' "$*" >> "$STATE/cmd" ;;
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
      *) echo "stub tmux: unexpected format: $5" >&2; exit 64 ;;
    esac
    ;;
  send-keys)
    # send-keys -t <session> <key>
    printf '%s\n' "$4" >> "$STATE/keys"
    # Digits advance as well as Enter: claude's menus act on the number key
    # alone, which is the whole reason answer_gate has to check afterwards
    # whether the gate is still up before confirming.
    case "$4" in
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

# --- the resume chooser is answered, and the session comes up ---------------
new_case resume_gate
resume_prompt "$STATE/screen"
# Picking an entry advances straight past it: claude's menus act on the digit.
banner "$STATE/step1"; banner "$STATE/screen1"
run_cmd start

check "the resume prompt verifies"      '[ "$RC" -eq 0 ]'
check "session left running"            '[ -f "$STATE/session" ]'
check "picks 'Resume from summary'"     '[ "$(head -n1 "$STATE/keys")" = 1 ]'
check "no stray Enter once it advances" '! grep -qx Enter "$STATE/keys"'
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
check "picks 'Auto (match terminal)'"    '[ "$(head -n1 "$STATE/keys")" = 1 ]'
check "says what it did"                 'grep -q "answering the theme picker" "$OUT"'

# --- all three gates in a row, which is what a fresh machine actually shows -
# Modelled the way claude really behaves: the number key alone dismisses each
# menu. The scrollback accumulates, so every gate stays matchable there, while
# the screen shows only the gate currently up. A watchdog that confirmed with
# an unconditional Enter would land it on the *next* screen — and since the
# Bypass warning that follows the trust prompt leads with "No, exit", that
# stray Enter quits claude. So: three digits, and not one Enter.
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
check "theme answered first"    '[ "$(head -n1 "$STATE/keys")" = 1 ]'
check "trust answered next"     '[ "$(grep -x "[12]" "$STATE/keys" | sed -n 2p)" = 1 ]'
check "bypass answered last"    '[ "$(grep -x "[12]" "$STATE/keys" | sed -n 3p)" = 2 ]'
check "one digit per gate"      '[ "$(grep -cx "[12]" "$STATE/keys")" -eq 3 ]'
check "no stray Enter is sent"  '! grep -qx Enter "$STATE/keys"'

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
# Most spawn failures have nothing to do with the transcript — no network, a
# logout — so one is not enough to throw the conversation away. Three in a row
# is, otherwise a transcript claude refuses to open wedges the service forever.
new_case resume_gives_up
pin_id 11111111-2222-3333-4444-555555555555
write_transcript 11111111-2222-3333-4444-555555555555
run_cmd start                                   # never ready: verification fails
check "one failure keeps the conversation"  '[ "$(saved_id)" = 11111111-2222-3333-4444-555555555555 ]'
run_cmd start
check "two failures keep it too"            '[ "$(saved_id)" = 11111111-2222-3333-4444-555555555555 ]'
run_cmd start
check "the third gives up on it"            '[ -z "$(saved_id)" ]'
check "and says so"                         'grep -q "starting a new one" "$OUT"'

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
pin_id 11111111-2222-3333-4444-555555555555
write_transcript 11111111-2222-3333-4444-555555555555
run_cmd start                       # fails: no banner
banner "$STATE/pane"
run_cmd start                       # succeeds, clearing the count
: > "$STATE/pane"
run_cmd start                       # fails again — but as the first, not the second
banner "$STATE/pane"
run_cmd start

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
check "picks 'Resume from summary'"        '[ "$(head -n1 "$STATE/keys")" = 1 ]'
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

rm -rf "$ROOT"
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
