# claude-tmux-service

Keep a [Claude Code **Remote Control**](https://code.claude.com/docs/en/remote-control)
session running on your machine as a background service, inside a persistent
[tmux](https://github.com/tmux/tmux) session — so you can drive it from the
Claude mobile app or [claude.ai/code](https://claude.ai/code) at any time, and
it comes back on its own after crashes, network drops, or reboots.

Works anywhere Claude Code runs: any **systemd** Linux (Arch, Raspberry Pi OS /
Debian, Fedora, …) and **macOS** (launchd).

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
indefinitely.

## Requirements

- **tmux**
- **Claude Code** ≥ 2.1.51 (`claude --version`)
- A **claude.ai Pro or Max** login (`claude` → `/login`). Remote Control does
  **not** work with API keys or `ANTHROPIC_BASE_URL` pointing away from
  `api.anthropic.com`.
- Linux: a systemd **user** session. macOS: launchd (built in).
- Optional: **`nm-online`** (ships with NetworkManager; present on Arch,
  Raspberry Pi OS / Debian Bookworm+, Fedora, …) for the pre-spawn network
  wait. Without it the post-spawn verification still covers you.

## Install

```sh
git clone https://github.com/<you>/claude-tmux-service.git
cd claude-tmux-service
./install.sh
```

One command on both platforms — `install.sh` detects the OS and wires up
systemd or launchd accordingly. It:

1. copies `claude-remote-start.sh` to `~/.local/bin/`
2. installs the service unit (systemd user unit, or a launchd LaunchAgent)
3. on Linux, enables lingering so the service survives logout / reboot
4. starts the service immediately

Then, from your phone or browser, open the session (named after your machine's
hostname by default) in the Claude app under **Code** — it shows a laptop icon
with a green **Connected** dot.

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
Exits non-zero if the session is missing, or running but not registered — the
one check that distinguishes "a session exists" from "my phone can see it".

**Attach to the live session (any platform):**
```sh
tmux attach -t "$(hostname -s)"     # or your CLAUDE_TMUX_SESSION
# detach with Ctrl-b d — claude keeps running
```

## Uninstall

```sh
./uninstall.sh
```

Stops and removes the service and the script. Your `~/.config/claude-tmux/`
config, if any, is left untouched.

## Troubleshooting

- **App shows a cloud icon instead of a laptop icon.** That entry is a *Claude
  Code on the web* (cloud) session, not this local Remote Control session. A
  connected local session shows a **laptop icon + green dot**. See the
  [icon meaning in the docs](https://code.claude.com/docs/en/remote-control#connect-from-another-device).
- **Nothing shows up in the app, and the logs repeat "claude exited Ns after
  starting".** The account is logged out. Remote Control needs a claude.ai
  subscription session, and the OAuth tokens in `~/.claude/.credentials.json`
  can be dropped by a failed refresh — leaving `accessToken`/`refreshToken`
  empty and `expiresAt: 0` while `subscriptionType` still reads `pro`, so
  everything *looks* fine. Run `claude`: the footer says **"Not logged in ·
  Run /login"** and the header shows *API Usage Billing* instead of your plan.
  Fix with `/login`. On a headless box you can do this over SSH: start
  `tmux new-session -d -s login claude`, `tmux send-keys -t login "/login"
  Enter`, read the OAuth URL out of `tmux capture-pane -p -t login`, approve it
  in a browser, then paste the code back with `tmux send-keys -t login -l
  '<code>'`.
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
