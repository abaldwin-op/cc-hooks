# Notifications

Toast notifications for [Claude Code](https://claude.com/product/claude-code) via Windows' WinRT API.

## Why not just use...

**Built-in terminal notifications?** [Windows Terminal](https://aka.ms/terminal) doesn't support Claude Code's [built-in desktop notifications](https://code.claude.com/docs/en/terminal-config#notification-setup). [Ghostty](https://ghostty.org/) and [Kitty](https://sw.kovidgoyal.net/kitty/) are not available on Windows. [WezTerm](https://wezfurlong.org/wezterm/) does run on Windows and supports built-in notifications, but clicking them only brings the window to the foreground — not the originating tab or pane ([PR #7643](https://github.com/wez/wezterm/pull/7643) is open to fix this).

**[BurntToast](https://github.com/Windos/BurntToast)?** It's a PowerShell module — every hook invocation pays PowerShell's startup cost. Click actions still require protocol handlers, and you'd need to build all the session tracking, elapsed time, and editor integration on top. This project uses the WinRT API directly from a compiled Rust binary.

## What it does

When Claude finishes or needs input, you get a toast notification showing:
- **Project directory** and **elapsed time** (e.g., "Task completed (12s)")
- **Focus Terminal** button — brings Windows Terminal to front and switches to the correct tab (preserves snap/maximize layout)
- **Open in Editor** button — opens the project directory in your configured editor
- Clicking the notification body focuses the terminal
- Notifications replace by session (no stacking)
- Optional **webhook** — sends to Discord, Slack, ntfy, etc. when you're AFK
- Skips IDE terminals (VS Code, Zed, Cursor) — only fires in Windows Terminal
- Per-type notification messages and icons (see `config.json.example`)

## Setup

```powershell
cd windows
pwsh -NoProfile -File install.ps1
```

This builds the binary, registers protocol handlers (`claude-focus://`, `claude-editor://`), sets up the notification AUMID (with icon), and merges hooks into `~/.claude/settings.json`. A UAC prompt will appear for the icon registry entry — declining still works, just no icon on toasts.

### Prerequisites

- [Rust](https://rustup.rs/)
- [PowerShell 7+](https://github.com/PowerShell/PowerShell) (`pwsh`)

### Build (manual)

```powershell
cd windows\notifications
cargo build --release
```

The binary is at `target\release\notifications.exe`.

### Uninstall

```powershell
cd windows
pwsh -NoProfile -File uninstall.ps1
```

Removes hooks from `~/.claude/settings.json`, protocol handlers (HKCU), AUMID registry keys, and cleans up watcher processes.

## Configuration

Copy `config.json.example` to `config.json` and edit:

```json
{
    "title": "CC Notification",
    "editor": "zed",
    "desktop": true,
    "messages": {
        "notification": "Claude needs your input",
        "permission": "Claude needs permission",
        "elicitation": "Action required",
        "idle": "Claude is waiting",
        "stop": "Task completed"
    },
    "icons": {
        "notification": "icons/notification.png",
        "permission": "icons/notification.png",
        "elicitation": "icons/notification.png",
        "idle": "icons/notification.png",
        "stop": "icons/stop.png",
        "title": "icons/title.ico"
    },
    "webhook": {
        "enabled": true,
        "url": "",
        "idle_minutes": 15,
        "payload": "webhook.discord.json"
    }
}
```

| Field | Description |
|-------|-------------|
| `title` | Name shown in toast attribution bar (registered in HKLM during install) |
| `editor` | Editor to open projects in (`zed`, `code`, `cursor`) |
| `desktop` | Set to `false` to skip desktop notifications (webhook-only mode) |
| `sound` | `"default"`, a sound name (see below), or `""` to disable |

#### Sound names

Windows toast sounds use `ms-winsoundevent:Notification.{name}`. Valid names:

`Default`, `IM`, `Mail`, `Reminder`, `SMS`

### Icons

Place in `icons/` (gitignored). Each notification type can have its own icon — see `config.json.example` for all slots. Types without a specific icon fall back to `notification`.

### Webhook

Sends a JSON POST when you're AFK (idle for `idle_minutes`). Useful for Discord, Slack, ntfy, Gotify, etc.

| Field | Description |
|-------|-------------|
| `webhook.enabled` | Set to `false` to disable without removing config |
| `webhook.url` | Webhook endpoint (leave empty to disable) |
| `webhook.idle_minutes` | Minutes of inactivity before sending (default: 15, `0` = always send) |
| `webhook.payload` | Path to JSON template file (relative to notifications/) |

Copy a service-specific example and customize:
- `webhook.discord.json.example` — [Discord](https://discord.com/)
- `webhook.slack.json.example` — [Slack](https://slack.com/)
- `webhook.ntfy.json.example` — [ntfy](https://ntfy.sh/)
- `webhook.gotify.json.example` — [Gotify](https://gotify.net/)

Template variables: `{{title}}`, `{{message}}`, `{{elapsed}}`, `{{project}}`, `{{event}}`, `{{notification_type}}`

## Files

| File | Purpose |
|------|---------|
| `src/main.rs` | Rust source — all hook commands, focus watcher, install/uninstall |
| `Cargo.toml` | Build configuration + dependencies |
| `config.json.example` | Example config (copy to `config.json`) |
