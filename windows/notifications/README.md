# Notifications

Toast notifications for Claude Code via Windows' WinRT API.

## What it does

When Claude finishes or needs input, you get a toast notification showing:
- **Project directory** and **elapsed time** (e.g., "Task completed (12s)")
- **Focus Terminal** button — brings Windows Terminal to front and switches to the correct tab
- **Open in Editor** button — opens the project directory in your configured editor
- Clicking the notification body also focuses the terminal

Skips notifications when running inside an IDE (Zed, VS Code, etc.).

## Configuration

Edit `config.json`:

```json
{
    "editor": "zed",
    "messages": {
        "notification": "Claude needs your input",
        "stop": "Task completed"
    },
    "icons": {
        "notification": "icons/notification.png",
        "stop": "icons/stop.png"
    }
}
```

### Icons

Place in `icons/` (gitignored):
- `notification.png` — shown when Claude needs input
- `stop.png` — shown when Claude finishes
- `title.ico` — small icon in the notification attribution bar

## Files

| File | Purpose |
|------|---------|
| `src/Program.cs` | C# source — all hook commands + focus watcher |
| `src/Notifications.csproj` | Build configuration |
| `config.json` | Editor, messages, and icon paths |
| `ShortcutAumid.cs` | Sets AUMID on Start Menu shortcut (used by install) |
