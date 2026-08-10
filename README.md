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
2. **installs Claude Code** if `claude` is not on `PATH`, with the official
   installer (`curl -fsSL https://claude.ai/install.sh | bash`). No `sudo`.
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
Claude Code warns three days ahead at startup, and
`claude-remote-start.sh status` will start reporting the session as not
registered. Re-run `claude auth login` to renew.

## Requirements

Handled for you by `install.sh`, listed here for reference:

- **tmux**
- **Claude Code** ≥ 2.1.51 (`claude --version`)
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

# ceiling for the retry delay after repeated failures, seconds
CLAUDE_TMUX_MAX_BACKOFF=300

# answer claude's first-run gates automatically — the "do you trust this
# folder?" prompt and the Bypass Permissions warning — which nothing else
# would answer in an unattended session; 0 to answer them by hand
CLAUDE_TMUX_AUTO_TRUST=1
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
```
The one check that distinguishes "a session exists" from "my phone can see it".
Exit codes: `0` registered, `1` missing or running-but-not-registered, `2`
running but unconfirmable.

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

Detects the OS the same way the installer does, then stops the tmux session and
removes the service (systemd unit or LaunchAgent) and the script.

It deliberately removes only what this repo installed. Your
`~/.config/claude-tmux/` config is left alone, and so are tmux and Claude Code —
even if `install.sh` was the thing that installed them, they are ordinary
packages you may well be using for something else.

## Tests

```sh
sh tests/install.test.sh
```

Runs `install.sh` end to end against stubbed tools in a throwaway `HOME`,
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

  Note the two menus number their entries in opposite orders — the trust prompt
  leads with "Yes, I trust this folder", the Bypass warning with "No, exit" — so
  each is answered by name, not by position.
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
- **The session is killed and recreated every few minutes, but `tmux attach`
  shows a healthy, connected claude.** The verification banner no longer
  matches. Check what the pane actually prints and set `CLAUDE_TMUX_READY` to a
  substring of it — or set `CLAUDE_TMUX_VERIFY=0` to turn verification off.
- **`claude` not found.** The watchdog searches `~/.local/bin`, linuxbrew,
  Homebrew (ARM + Intel), and `/usr/local/bin`. If Claude Code lives elsewhere,
  add its directory to `PATH` in `~/.config/claude-tmux/env`.

## License

MIT — see [LICENSE](LICENSE).
