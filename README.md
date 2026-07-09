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

## Requirements

- **tmux**
- **Claude Code** ≥ 2.1.51 (`claude --version`)
- A **claude.ai Pro or Max** login (`claude` → `/login`). Remote Control does
  **not** work with API keys or `ANTHROPIC_BASE_URL` pointing away from
  `api.anthropic.com`.
- Linux: a systemd **user** session. macOS: launchd (built in).

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

**macOS (launchd):**
```sh
launchctl print gui/$(id -u)/com.claude-tmux | head
launchctl kickstart -k gui/$(id -u)/com.claude-tmux   # restart
tail -f ~/Library/Logs/claude-tmux.log
```

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
- **Session disappears after ~10 minutes offline.** By design: if the machine
  can't reach the network for ~10 minutes, `claude` times out and exits. The
  watchdog then recreates the session once connectivity is back.
- **Migrating from a hand-rolled unit** (e.g. an older `claude-remote.service`):
  disable it first so the two don't fight —
  `systemctl --user disable --now claude-remote.service` and remove its unit
  file — then run `./install.sh`.
- **`claude` not found.** The watchdog searches `~/.local/bin`, linuxbrew,
  Homebrew (ARM + Intel), and `/usr/local/bin`. If Claude Code lives elsewhere,
  add its directory to `PATH` in `~/.config/claude-tmux/env`.

## License

MIT — see [LICENSE](LICENSE).
