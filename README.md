# claude-tmux-service

Keep a [Claude Code **Remote Control**](https://code.claude.com/docs/en/remote-control)
session running on your machine as a background service, inside a persistent
[tmux](https://github.com/tmux/tmux) session — so you can drive it from the
Claude mobile app or [claude.ai/code](https://claude.ai/code) at any time, and
it comes back on its own after crashes, network drops, or reboots.

Works anywhere Claude Code runs: any **systemd** Linux (Arch, Raspberry Pi OS /
Debian, Fedora, …) and **macOS** (launchd), on both x86-64 and ARM64 — including
Apple Silicon and the Raspberry Pi.

## How it works

```
service manager  ──▶  watchdog loop  ──▶  tmux session  ──▶  claude --remote-control
(systemd/launchd)     (every 30s)         (detached)         (your real session)
```

- The **service manager** (systemd on Linux, launchd on macOS) starts the
  watchdog at login/boot and restarts it if it ever dies.
- The **watchdog** (`claude-remote-start.sh`) checks every 30 seconds whether
  the tmux session exists. If `claude` exited — network timeout, crash, `/exit`
  — the session is gone and the watchdog recreates it. When the network returns,
  the session reconnects within one interval.
- The session runs inside **tmux**, so you can `tmux attach` locally at any time
  without disturbing it.

Each layer heals the one below it: service manager → watchdog → tmux → claude.

### The conversation survives the restart

A watchdog that only keeps a session *alive* still loses the work: every
respawn used to open an empty claude, so a crash or a network timeout wiped
whatever was being worked on from the phone.

So the session is pinned to one conversation. The first spawn names it —
`claude --session-id <uuid>` — and records the id under the watchdog's state
dir; every later spawn reattaches with `claude --resume <uuid>`. Reconnect from
the app after a reboot and the history is still there.

The id is recorded rather than derived. `claude --continue` would take the most
recent conversation in `$HOME`, which is just as likely to be one you started by
hand in a terminal — the remote session would then wander into it.

The pin follows the conversation, not just the spawn. `/clear` — from the phone
as much as here — moves claude to a new conversation with a new id, and a pin
set once at spawn time would bring every later restart back to the one *before*
the `/clear`. So each spawn is started with `--settings` pointing at a small
file under the state dir that adds a `SessionStart` hook (it adds to your own
settings, it replaces nothing). claude fires that hook at startup, on resume,
on `/clear` and after compaction, and it calls back into
`claude-remote-start.sh record-session` to record the id it is in now. A claude
started by hand never gets the hook, so it cannot repoint the service.

Two escape hatches, because a pinned conversation is a thing that can go wrong:

- A transcript claude refuses to open would otherwise wedge the service for
  good. If it says so outright the conversation is dropped at once; otherwise
  it is dropped after three spawns in a row where claude, *signed in*, dies
  straight after starting — the one failure a transcript can cause. Everything
  else (no network, a logout, an expired token, a first-run prompt the watchdog
  could not answer, a banner that never showed) fails every spawn alike and is
  not charged to the conversation: one such streak once cost a whole
  conversation. Either way the next spawn starts a fresh conversation.
- `claude-remote-start.sh reset` forgets it deliberately, for when you just want
  a clean slate. `stop` does **not** — stopping the session isn't the same as
  abandoning what it was doing.

Dropping a conversation only drops the pointer. The transcript stays where
claude wrote it, the id is appended to `~/.local/state/claude-tmux/abandoned-sessions`,
and the log names the command that reopens it (`claude --resume <id>`).

Set `CLAUDE_TMUX_RESUME=0` to go back to an empty session every time.

### Why "is the session alive?" isn't enough

If `claude` starts a few seconds before the network is up, registering with
Remote Control fails — but `claude` **does not exit**. It carries on as an
ordinary local session. The tmux session exists, a naive watchdog is happy, and
the machine simply never shows up in the Claude app. This is the failure mode
you hit after a reboot.

Two things prevent it:

1. **Wait for the network before spawning.** A systemd *user* unit cannot order
   itself after `network-online.target` — that target doesn't exist in the user
   manager, so `After=`/`Wants=` are silently no-ops. The script asks
   NetworkManager directly (`nm-online`, over D-Bus, no HTTP probe).
2. **Verify after spawning.** The pane must show the
   `remote-control is active` banner within `CLAUDE_TMUX_VERIFY` seconds. If it
   doesn't, the session is killed and retried on the next pass.

Where `nm-online` isn't available (macOS, non-NetworkManager systems) step 1 is
skipped and step 2 does the work on its own.

### Registration is checked for as long as the session runs

Verifying a session on its way up says nothing about it an hour later, and the
same failure can arrive at any time: the claude.ai token behind Remote Control
expires every few hours, and a session whose token lapses keeps running as an
ordinary local session — registered with nothing. tmux still has a session, so
a watchdog that only asks *does the session exist?* stays satisfied while the
machine quietly stops answering from the Claude app.

So an already-running session is re-checked every `CLAUDE_TMUX_HEALTH` seconds.
If it reports a failed registration `CLAUDE_TMUX_HEALTH_STRIKES` checks running,
it is recycled — and recycling *is* the repair, because starting `claude` again
refreshes the token. No login is involved, which is why this isn't treated as a
logout.

### A blocked prompt is not a healthy session

Pinning the conversation has a consequence that shows up only after weeks:
a conversation grows, and past a size threshold `claude` stops resuming it
outright and asks first —

```
This session is 1d 5h old and 210.6k tokens.
  ❯ 1. Resume from summary (recommended)
    2. Resume full session as-is
    3. Don't ask me again
```

Nobody is watching this pane, so that question blocks forever. Worse, it is a
full-screen chooser: it covers the status bar the registration check reads, so
the session stops reporting `/rc failed` and starts reporting nothing at all.
Left to itself the machine sits offline behind a tmux session that looks
perfectly alive, and `systemctl status` says `active (running)` throughout.

Two answers, because one is not enough:

1. **The chooser is answered**, at spawn time and on a running session, with
   *Resume from summary* — it keeps the conversation, which is the whole point
   of pinning one, and sheds the weight that raised the question. Matched on
   the visible screen, never the scrollback, since this prompt recurs and a
   transcript that once discussed it contains the phrase verbatim.
2. **An unreadable status bar is counted**, over `CLAUDE_TMUX_UNKNOWN_STRIKES`
   checks, and then the session is recycled. This is the backstop for the next
   prompt, the one this script has not been taught yet. It only counts while
   claude's own prompt chrome is *not* on screen — see below.

### What counts as proof of registration

Claude Code prints the `remote-control is active` banner once, at startup, and
paints a status bar at the bottom of the pane — `/rc` when registered,
`/rc failed` when not. The status bar is the better witness: it is repainted
every frame, so it describes the session *now*.

The scrollback is not evidence, in either direction. `CLAUDE_TMUX_RESUME=1`
replays the previous conversation into the pane on every restart, so a session
that has ever discussed its own registration carries both the banner and a
`Remote Control disconnected` line in its history — neither of which says
anything about the present. So the checks read the status bar first and fall
back to the *opening* output; a phrase anywhere else is ignored.

**Current Claude Code shows neither for long.** It no longer paints `/rc` in
the status bar — busy or idle — and it draws on the alternate screen, so there
is no scrollback for the startup banner to survive in. A healthy session
therefore reads *unknown* as soon as the banner scrolls off, and counting that
recycled every session after half an hour of work, mid-task. So an unknown
reading is not counted while claude's own prompt chrome (the permission-mode
line: `bypass permissions`, `? for shortcuts`, `esc to interrupt`, …, set by
`CLAUDE_TMUX_CHROME`) is on the bottom lines: claude is up and nothing covers
it.

That leaves a registration dropped *silently*, with the chrome still up, with
nothing on screen to give it away. So instead of detecting it, the watchdog
renews it: a session that has been up for `CLAUDE_TMUX_REFRESH_AGE` (6 hours)
is restarted once its conversation has been quiet for `CLAUDE_TMUX_REFRESH_IDLE`
(30 minutes) — the same fresh start that renews an expired token. "Quiet" is
read from the conversation's transcript, which claude appends to on every
message, and a session showing `esc to interrupt` is never touched, since a
long tool call writes nothing until it returns. It costs nothing: the respawn
resumes the conversation claude was in. With `CLAUDE_TMUX_RESUME=0` there is
nothing to come back to, so no refresh happens.

When neither is conclusive the state is *unknown*. An unknown session is given
a long leash — far longer than a failing one — because killing a working
session over a future release renaming its chrome would be worse than the
problem being solved. But the leash ends: after `CLAUDE_TMUX_UNKNOWN_STRIKES`
consecutive unreadable checks the session is recycled anyway. Treating unknown
as *healthy*, with no limit, is exactly what once let a session sit wedged
behind a prompt for two days. Set `CLAUDE_TMUX_UNKNOWN_STRIKES=0` to restore
the old never-recycle behaviour.

Repeated failures back off — the retry delay doubles up to
`CLAUDE_TMUX_MAX_BACKOFF` — so a genuinely broken setup (logged out, banner
renamed) costs one attempt every few minutes instead of spinning at full rate
indefinitely. The log is deduplicated to match: within one failure streak each
distinct message is written once and further repeats are suppressed, so a
long-running broken state leaves a readable log instead of hundreds of copies
of the same lines. The next message is logged afresh once the situation changes
or a spawn finally succeeds.

## Platform support

|                     | Linux                                                        | macOS                                                             |
| ------------------- | ------------------------------------------------------------ | ----------------------------------------------------------------- |
| **OS**              | any distro with **systemd** (Arch, Raspberry Pi OS / Debian, Ubuntu, Fedora, …) | **macOS 13.0+** (Ventura or newer)              |
| **Architecture**    | x86-64 or ARM64                                              | Apple Silicon (M1/M2/M3/M4) or Intel — both native                 |
| **Service manager** | systemd **user** unit                                        | launchd **LaunchAgent**                                            |
| **Unit installed to** | `~/.config/systemd/user/claude-tmux.service`               | `~/Library/LaunchAgents/com.claude-tmux.plist`                     |
| **Runs without you logged in** | yes — installer runs `loginctl enable-linger`     | **no** — needs a GUI login, see [macOS notes](#macos-notes)         |
| **Pre-spawn network wait** | yes, via `nm-online`                                  | skipped; post-spawn verification covers it                         |
| **Logs**            | `journalctl --user -u claude-tmux.service`                   | `~/Library/Logs/claude-tmux.log`                                   |

Nothing in this repo is compiled — it is POSIX `sh` plus one unit file — so the
CPU architecture never matters on its own. An Apple Silicon MacBook and a
Raspberry Pi run the exact same script.

## Install

From a bare machine to a running session, on Linux and macOS alike:

```sh
git clone https://github.com/ErcouldnT/claude-tmux-service.git
cd claude-tmux-service
./install.sh
```

`install.sh` detects the OS with `uname -s` and does the whole job:

1. **installs tmux** if it is missing, using whichever package manager it finds
   — `pacman`, `apt-get`, `dnf`, `zypper`, `apk`, or `brew`. On a fresh Mac with
   no Homebrew it offers to install that first, since macOS ships no package
   manager and there is otherwise no way to get tmux.
2. **installs Claude Code** with the official installer
   (`curl -fsSL https://claude.ai/install.sh | bash`), unless that copy is
   already there. No `sudo`. A Homebrew or npm copy does not count: those stay
   on whatever version they were installed at, while the official one updates
   itself in the background. So if one is found, the official copy goes in
   next to it, the watchdog picks it up (`~/.local/bin` is first on its
   `PATH`), and the installer prints the command to remove the old one — it
   does not remove it for you. `--no-deps` leaves an existing copy alone.
3. **checks that you are logged in**, and runs the login flow for you if you are
   not — see [Login](#login) below.
4. copies `claude-remote-start.sh` to `~/.local/bin/`
5. installs the service unit (systemd user unit, or a launchd LaunchAgent)
6. on Linux, enables lingering so the service survives logout / reboot
7. starts the service — and **restarts** it if it was already running, so
   re-running the installer really does pick up a new version

Re-running `./install.sh` after `git pull` is the supported upgrade path.

Every command that needs elevation is printed before it runs, and on a terminal
you are asked before anything is installed. Nothing happens behind your back.

### Options

| Flag         | Effect                                                          |
| ------------ | --------------------------------------------------------------- |
| *(none)*     | install what's missing, log in if needed, install the service     |
| `--no-deps`  | install nothing; stop with a package-manager hint if tmux is missing |
| `--no-login` | skip the login check entirely                                     |
| `-y`, `--yes`| never pause for confirmation — for unattended provisioning        |

With no terminal attached (a provisioning script, CI) the installer never
blocks: it proceeds without prompting, and skips the interactive login instead
of hanging on it.

### Check it

```sh
~/.local/bin/claude-remote-start.sh status
# session 'pi5': running, registered with Remote Control
```

Then, from your phone or browser, open the session (named after your machine's
hostname by default) in the Claude app under **Code** — it shows a laptop icon
with a green **Connected** dot.

## Login

Remote Control needs a **claude.ai Pro or Max** subscription login. The
installer checks with `claude auth status --json`, which is the portable way to
ask: on macOS the credentials live in the encrypted Keychain, on Linux in
`~/.claude/.credentials.json`, and that command reads whichever applies.

If you are not logged in and a terminal is attached, the installer runs
`claude auth login` for you. It opens a browser; over SSH no browser opens, so
copy the URL it prints, approve it, and paste the code back.

You can always do it by hand:

```sh
claude auth login     # sign in
claude auth status    # check
```

### `claude-remote-start.sh login`

On a headless box, prefer this over `claude auth login`:

```sh
~/.local/bin/claude-remote-start.sh login
```

It handles the two situations separately, because they are not the same job:

- **A machine that has never been set up** gets the whole first run walked —
  theme picker, login method, the sign-in, the two "press Enter" notices, the
  trust prompt, the Bypass warning.
- **A machine that was set up long ago and has only had its token expire** gets
  `claude auth login` driven directly. There is no first-run screen to walk in
  that state: the TUI opens as an ordinary session and does not mention the
  lapsed token until something needs the network.

Either way it stops at the one step that genuinely needs a person: it prints
the sign-in URL and waits for you to paste the code back. Then it drops the
stale session so the watchdog rebuilds it within one interval.

Two reasons it exists rather than pointing you at `claude auth login`:

- **A CLI login does not clear a first run.** Onboarding runs its own sign-in
  step and ignores the token the subcommand stored, so `claude auth status` can
  report a healthy Pro login while every new session still opens on the
  sign-in screen. Only finishing the run in the TUI settles it.
- **The URL is unreadable as captured.** The TUI draws it itself, one screenful
  per rendered line, so `capture-pane -J` has no wrap flags to rejoin and hands
  back the first ~200 characters. A truncated OAuth URL fails at claude.com
  with nothing to explain why. The URL is reassembled before you see it.

Leaving the run unfinished is not harmless: `hasCompletedOnboarding` is only
written once it reaches the end, so a session killed at the sign-in screen
sends the machine back to the theme picker on every start, forever. `login`
waits for that flag before reporting success.

But that flag is only half the answer, and reading it as the whole answer was a
bug worth naming here: it is written once and never cleared, so on an onboarded
machine it stays true no matter what happens to the token. `login` used to stop
at it and report success — instantly, without ever printing a URL — on exactly
the machine it exists to repair. Success now means the flag **and** a live
`claude auth status`.

> **⚠️ Two credentials that look fine but cannot host a session.** The installer
> warns about both, because the watchdog would otherwise retry forever on a
> machine that reports itself as logged in:
>
> - **`CLAUDE_CODE_OAUTH_TOKEN`** — the long-lived token from
>   `claude setup-token`. It is the obvious choice for headless automation, and
>   it does not work here: it can only make model requests, and
>   [cannot establish Remote Control sessions](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token).
> - **`ANTHROPIC_API_KEY`** / **`ANTHROPIC_AUTH_TOKEN`** — these take precedence
>   over your subscription login, and Remote Control needs the subscription.
>   `unset` them.
>
> `ANTHROPIC_BASE_URL` pointing away from `api.anthropic.com` breaks it too.

A login that expires while nobody is watching stops the session for good —
Claude Code warns three days ahead at startup. When the watchdog then finds
itself logged out it can't recover on its own (that needs an interactive
login), so instead of spinning silently it:

- raises a **desktop notification** telling you to log back in (macOS
  `osascript`/`terminal-notifier`, Linux `notify-send`; set
  `CLAUDE_TMUX_NOTIFY=0` to opt out), and
- makes `claude-remote-start.sh status` report `not running — logged out of
  claude.ai` with the exact command to fix it, rather than a bare "not
  running".

Re-run `claude auth login` to renew; the next successful spawn clears the
logged-out state on its own.

## Requirements

Handled for you by `install.sh`, listed here for reference:

- **tmux**
- **Claude Code** ≥ 2.1.51 (`claude --version`), from the official installer so it
  keeps itself up to date
- a claude.ai **Pro or Max** login
- Optional: **`nm-online`** (ships with NetworkManager; present on Arch,
  Raspberry Pi OS / Debian Bookworm+, Fedora, …) for the pre-spawn network
  wait. Without it the post-spawn verification still covers you.

## macOS notes

Everything below is specific to macOS; Linux users can skip this section.

**The service only runs while you are logged in.** A LaunchAgent lives in the
`gui/$(id -u)` domain, which exists only once a user has logged in to the
desktop. There is no macOS equivalent of `loginctl enable-linger`: after a
reboot, the session comes back when you log in, not at the login window. If you
need a Mac that reconnects with nobody logged in, that requires a *LaunchDaemon*
running as root — out of scope here, since Claude Code's credentials are
per-user.

**A laptop that sleeps drops the session.** Closing the lid suspends tmux and
`claude` along with everything else, and the machine goes offline in the Claude
app. On wake, the watchdog notices within one interval and reconnects — but if
you want a MacBook to stay reachable, keep it awake and on power:

```sh
caffeinate -s          # foreground: prevent sleep while this runs (AC power only)
sudo pmset -c sleep 0  # persistent: never sleep while on the power adapter
pmset -g              # check current settings
```

Closing the lid still sleeps the machine regardless, unless it is in clamshell
mode — external display plus power connected.

**Pick a nicer session name.** The default is `hostname -s`, and macOS derives
that from the computer's name, so "Erkut's MacBook Pro" becomes
`Erkuts-MacBook-Pro` — long and awkward in the Claude app. Set something short
in `~/.config/claude-tmux/env`:

```sh
CLAUDE_TMUX_SESSION=mbp
```

## Configuration

Optional. Create `~/.config/claude-tmux/env` to override defaults:

```sh
# tmux session name — also the session title shown in the Claude app
# (default: short hostname, e.g. "pi5" or "arch")
CLAUDE_TMUX_SESSION=my-box

# extra args passed to `claude --remote-control`
# default runs with permission checks bypassed; set empty to keep prompts
CLAUDE_TMUX_ARGS=--dangerously-skip-permissions

# watchdog check interval, seconds
CLAUDE_TMUX_INTERVAL=30

# how long to wait for the "registered" banner after spawning, seconds
# (0 disables verification)
CLAUDE_TMUX_VERIFY=60

# how long to wait for NetworkManager before spawning, seconds
# (0 disables the wait; ignored where nm-online is missing)
CLAUDE_TMUX_NET_WAIT=55

# the banner that means "registered with Remote Control"
# override only if a future Claude Code release renames it
CLAUDE_TMUX_READY=remote-control is active

# the status bar text that means "registered" / "registration failed"
# override only if a future Claude Code release renames them
CLAUDE_TMUX_RC_OK=/rc
CLAUDE_TMUX_RC_FAILED=/rc failed

# how often to re-check a session that is already running, seconds
# (0 disables the check and restores the old spawn-time-only behaviour)
CLAUDE_TMUX_HEALTH=300

# consecutive failed checks before the session is recycled — more than one, so
# a reconnect that is merely in progress is given time to finish
CLAUDE_TMUX_HEALTH_STRIKES=2

# consecutive checks with an *unreadable* status bar before the session is
# recycled — a much longer leash than an outright failure, because the usual
# cause is nothing at all; 0 never recycles on an unknown reading
CLAUDE_TMUX_UNKNOWN_STRIKES=6

# the menu text of the prompt claude raises before resuming a large
# conversation, which the watchdog answers with "Resume from summary"
# override only if a future Claude Code release renames it
CLAUDE_TMUX_RESUME_GATE=Resume from summary

# restart a session this old (seconds) to renew its Remote Control
# registration — only while idle, and back into the same conversation;
# 0 never refreshes
CLAUDE_TMUX_REFRESH_AGE=21600

# ...and only once the conversation has been quiet this long (seconds)
CLAUDE_TMUX_REFRESH_IDLE=1800

# |-separated text that means claude's own prompt chrome is on the bottom
# lines, so an unreadable registration is not counted as a wedge
CLAUDE_TMUX_CHROME=bypass permissions|for shortcuts|shift+tab to cycle|esc to interrupt

# ceiling for the retry delay after repeated failures, seconds
CLAUDE_TMUX_MAX_BACKOFF=300

# answer claude's first-run gates automatically — the "do you trust this
# folder?" prompt and the Bypass Permissions warning — which nothing else
# would answer in an unattended session; 0 to answer them by hand
CLAUDE_TMUX_AUTO_TRUST=1

# raise a desktop notification when a logout is detected — the one failure the
# watchdog cannot fix on its own; 0 to stay silent and rely on the log
CLAUDE_TMUX_NOTIFY=1

# reattach every restart to the same conversation, so a crash or a reboot does
# not throw away what the session was doing; 0 to start empty every time
CLAUDE_TMUX_RESUME=1
```

Re-run `./install.sh` (or restart the service) after editing.

> **⚠️ Security note:** the default `CLAUDE_TMUX_ARGS` includes
> `--dangerously-skip-permissions`, so the remote session runs tools without
> asking. This is convenient for a trusted personal machine but means anyone
> who can reach the session can run commands on it. To keep permission prompts,
> set `CLAUDE_TMUX_ARGS=` (empty) in the config file.

## Managing the service

**Linux (systemd):**
```sh
systemctl --user status claude-tmux.service
systemctl --user restart claude-tmux.service
journalctl --user -u claude-tmux.service -f
```

> **Raspberry Pi OS (and any distro with `Storage=volatile`):** that
> `journalctl --user` command comes back empty — always. Raspberry Pi OS ships
> `/usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf` to spare the
> SD card, and no per-user journal file is created at all. The watchdog's
> output is not lost: it reaches the system journal, and `ForwardToSyslog=yes`
> puts it in `/var/log/syslog`, which *does* survive reboots. Read it with:
> ```sh
> grep claude-tmux /var/log/syslog     # persistent, spans reboots
> journalctl -b | grep claude-tmux     # this boot only
> ```

**macOS (launchd):**
```sh
launchctl print gui/$(id -u)/com.claude-tmux | head
launchctl kickstart -k gui/$(id -u)/com.claude-tmux   # restart
tail -f ~/Library/Logs/claude-tmux.log
```

**Is it actually registered? (any platform):**
```sh
~/.local/bin/claude-remote-start.sh status
# session 'pi5': running, registered with Remote Control
# conversation 6f1c…-…-…  — kept across restarts
```
The one check that distinguishes "a session exists" from "my phone can see it".
Exit codes: `0` registered, `1` missing or running-but-not-registered, `2`
running but unconfirmable — which, on a Claude Code that no longer shows its
registration, is the normal reading once the banner has scrolled off. The
second line names the pinned conversation, the one every restart reattaches
to (after a `/clear`, the new one).

**Start over with an empty conversation:**
```sh
~/.local/bin/claude-remote-start.sh reset
```
Forgets the pinned conversation and drops the session; the watchdog rebuilds it
empty within one interval. Use `stop` when you want the session gone but the
thread kept.

That third state is real rather than a hedge. The evidence is the startup
banner, which lives at the top of the pane's history, and `status` reads only
that opening stretch — never the whole scrollback, because a live claude asked
about its own banner puts the phrase back on screen, and a session that merely
*discussed* the banner would then pass. Once the session has produced more
output than tmux's `history-limit`, those opening lines are gone; absence stops
being evidence and `status` says so instead of guessing.

**Attach to the live session (any platform):**
```sh
tmux attach -t "$(hostname -s)"     # or your CLAUDE_TMUX_SESSION
# detach with Ctrl-b d — claude keeps running
```

## Uninstall

```sh
./uninstall.sh
```

Detects the OS the same way the installer does, then removes the service
(systemd unit or LaunchAgent), stops the tmux session and deletes the script.
That much always happens — it is what running this means. Everything else it
asks about:

| Question | Default |
| --- | --- |
| Remove `~/.config/claude-tmux/` | yes |
| Remove the watchdog's state dir | yes |
| Disable `loginctl` lingering | yes |
| Log out of claude.ai | **no** |
| Uninstall Claude Code | **no** |
| Delete `~/.claude` and `~/.claude.json` | **no** |
| Uninstall tmux | **no** |

The split is the point. The first three are things this service put there, so
an unattended run cleans them up. The rest are shared with the whole machine —
uninstalling tmux takes out every other tmux session on the box, and logging
out affects every use of Claude Code, not just this one. Those need an explicit
yes: with no terminal to ask, the answer is no.

```sh
./uninstall.sh                  # ask about each of the above
./uninstall.sh --yes            # the service and its own leftovers, nothing shared
./uninstall.sh --all            # everything, including Claude Code and tmux
./uninstall.sh --yes --logout   # or pick individually
```

`--keep-config`, `--keep-state` and `--keep-linger` opt out one at a time;
`--logout`, `--remove-claude`, `--remove-data` and `--remove-tmux` opt in.

Two orderings matter and are covered by the tests. The service is stopped
**before** its session is killed — reverse them and the still-running watchdog
does what it is built to do, spawning a replacement session that outlives the
uninstall. And the logout runs **before** Claude Code is removed, since the
logout goes through that binary; the other way round leaves credentials on disk
with nothing left to clear them.

Lingering is asked about rather than simply undone: `install.sh` turns it on,
but it is a per-user machine setting, and anything else you run as a user
service is relying on it too.

## Tests

```sh
sh tests/install.test.sh
sh tests/start.test.sh
sh tests/uninstall.test.sh
```

`uninstall.test.sh` covers what each flag does and does not touch, both
orderings described above, the warning when other tmux sessions would be lost,
and that a second run on an already-clean machine is a no-op rather than an
error.

`install.test.sh` runs `install.sh` end to end against stubbed tools in a throwaway `HOME`,
covering both platforms: the systemd and launchd paths, the auto-install and
`--no-deps` paths, logged-in / logged-out / wrong-credential-kind handling, and
that a re-run really restarts the service. It touches nothing outside its
temporary directory, so it is safe to run on the machine that hosts a live
session.

## Troubleshooting

- **App shows a cloud icon instead of a laptop icon.** That entry is a *Claude
  Code on the web* (cloud) session, not this local Remote Control session. A
  connected local session shows a **laptop icon + green dot**. See the
  [icon meaning in the docs](https://code.claude.com/docs/en/remote-control#connect-from-another-device).
- **Nothing shows up in the app, and the logs repeat "claude exited Ns after
  starting".** The account is logged out. Check with `claude auth status` and
  fix with `claude auth login` — both work fine over SSH. The failure is easy to
  miss on Linux, where a failed token refresh empties `accessToken` /
  `refreshToken` and sets `expiresAt: 0` in `~/.claude/.credentials.json` while
  `subscriptionType` still reads `pro`, so the file *looks* healthy. `claude
  auth status` reports `"loggedIn": false` regardless, on either platform.
- **`tmux attach` shows a prompt waiting for an answer** — "Quick safety check:
  Is this a project you created or one you trust?", or the pink "Claude Code
  running in Bypass Permissions mode" warning. Claude Code puts both in front of
  a machine's first run and blocks on them, so Remote Control never starts and
  the session is recycled every minute. Easy to hit on a *second* machine, whose
  home directory has not been trusted yet, and the Bypass warning is guaranteed
  as long as `CLAUDE_TMUX_ARGS` keeps its `--dangerously-skip-permissions`
  default. The watchdog answers both and logs `answering the …`; claude saves
  the answers in `~/.claude.json`, so each fires once per machine. Set
  `CLAUDE_TMUX_AUTO_TRUST=0` to answer them by hand instead.

  A brand-new install shows a third gate first, the **theme picker**, which the
  watchdog answers with "Auto (match terminal)".

  Each is answered by the *text* of the entry, never by its position or number:
  the watchdog finds the highlight on the visible screen, steps to the entry
  with the arrow keys, and confirms with one Enter. Nothing about these menus
  is stable enough to answer any other way. They disagree about which entry
  leads — the Bypass warning opens on "No, exit" — they have been numbered and
  unnumbered, and the trust prompt has shipped both orders. Pressing a digit is
  the trap: on an unnumbered menu it does nothing at all, and the Enter behind
  it then confirms whatever happens to be highlighted. When that was "No, exit"
  the session quit ten seconds after every spawn and the watchdog respawned it
  into the same trap, which reads in the log as `claude exited 10s after
  starting` and is easy to misread as a login problem.

  An entry the watchdog cannot find on screen is reported rather than guessed
  at — `could not find an entry matching …` — and the spawn fails. Pressing
  Enter on an unrecognised menu would answer whichever entry leads, and on two
  of these three that is the one that quits.
- **Every start opens on the theme picker, or on the sign-in screen.** The first
  run was never finished, so nothing was recorded: `hasCompletedOnboarding` is
  absent from `~/.claude.json`. The sign-in step needs a person, and the
  watchdog says so rather than burning its verification budget in front of a
  screen that cannot advance. Run `claude-remote-start.sh login` to walk it
  through — and note that `claude auth login` alone will *not* fix this, however
  healthy `claude auth status` looks afterwards.
- **macOS pops "Terminal wants to access files in your Desktop folder"
  dialogs.** That is macOS's own privacy gate, not Claude Code's, triggered the
  first time the session touches those directories. Approve them once; they are
  per-folder and do not come back.
- **Session disappears after ~10 minutes offline.** By design: if the machine
  can't reach the network for ~10 minutes, `claude` times out and exits. The
  watchdog then recreates the session once connectivity is back.
- **Migrating from a hand-rolled unit** (e.g. an older `claude-remote.service`):
  disable it first so the two don't fight —
  `systemctl --user disable --now claude-remote.service` and remove its unit
  file — then run `./install.sh`.
- **The machine stops answering from the Claude app, but the service is
  `active (running)` and `tmux attach` shows claude alive.** Look at the bottom
  of the pane: `/rc failed`, usually with a `Remote Control disconnected —
  /login` line above it. The claude.ai token expired — commonly because the
  session was started *after* it lapsed, or ran past its few-hour lifetime — so
  claude carried on as an ordinary local session that is registered with
  nothing. The health check now catches this and recycles the session, which
  refreshes the token; `claude-remote-start.sh stop && claude-remote-start.sh
  start` does it immediately. This needs no login, so `status` reports a failed
  registration rather than a logout.
- **The machine is offline, the service is `active (running)`, and `tmux
  attach` shows claude sitting on a question nobody answered.** Usually the
  resume chooser (`Resume from summary / Resume full session as-is`), raised
  because the pinned conversation grew large. It blocks startup and covers the
  status bar, so `status` reports the registration as *unconfirmed* rather than
  failed. Current versions answer it automatically; if you are looking at one
  anyway, press `1`, and check that `CLAUDE_TMUX_RESUME_GATE` still matches the
  menu text. `claude-remote-start.sh reset` drops the conversation entirely if
  you would rather it stopped growing.
- **The session is killed and recreated every few minutes, but `tmux attach`
  shows a healthy, connected claude.** The verification markers no longer
  match. Check what the pane's status bar actually prints and set
  `CLAUDE_TMUX_RC_OK` / `CLAUDE_TMUX_RC_FAILED` (or `CLAUDE_TMUX_READY` for the
  startup banner) to a substring of it. If the bar is simply unreadable to the
  script, `CLAUDE_TMUX_UNKNOWN_STRIKES=0` stops it recycling on that alone —
  or set `CLAUDE_TMUX_HEALTH=0` to stop re-checking a running session and
  `CLAUDE_TMUX_VERIFY=0` to turn spawn verification off.
- **The session comes back empty after a restart.** Check `status` for the
  `conversation …` line. No line means nothing is pinned — either
  `CLAUDE_TMUX_RESUME=0`, or the conversation was dropped because it kept
  failing to start (the log says `starting a new one`). Note the pin is per
  machine and lives in the watchdog's state dir, so a `--yes` uninstall clears
  it along with everything else the service put there.
- **A resumed session replays its transcript into the pane.** Harmless in
  itself, but it shares the scrollback with the registration check: a
  conversation that once *discussed* the `remote-control is active` banner puts
  that phrase back on screen, and `status` can then report a session as
  registered on the strength of the replay rather than the real banner. If you
  need the check to be exact, `CLAUDE_TMUX_READY` can be set to something the
  conversation will not say.
- **`claude` not found.** The watchdog searches `~/.local/bin`, linuxbrew,
  Homebrew (ARM + Intel), and `/usr/local/bin`. If Claude Code lives elsewhere,
  add its directory to `PATH` in `~/.config/claude-tmux/env`.

## License

MIT — see [LICENSE](LICENSE).
