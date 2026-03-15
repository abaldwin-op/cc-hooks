// Claude Code Hooks — Windows notification system
//
// Single exe with subcommands, called by Claude Code hooks in settings.json:
//   on-submit    — saves session state (timer, WT PID, tab ID), then runs focus watcher loop
//                  (async: true in settings.json so Claude doesn't wait)
//   notify       — shows toast notification via WinRT API
//   on-end       — kills watcher, cleans up temp files
//   trigger      — protocol handler for claude-focus:// (creates trigger file for watcher)
//   editor       — protocol handler for claude-editor:// (launches configured editor)
//
// Reads config from ../config.json (relative to bin/).
// Reads icons from ../icons/ (relative to bin/).
// Stores session data in %TEMP%/claude-timer-{session_id}.txt

using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Windows.Automation;
using Windows.Data.Xml.Dom;
using Windows.UI.Notifications;

// Application User Model ID — must match the AUMID set on the Start Menu shortcut
// by install.ps1. Windows uses this to associate toasts with the shortcut's name/icon.
const string AUMID = "ClaudeCode.Hooks";

// baseDir = windows/notifications/ (parent of bin/ where the exe lives)
var baseDir = Path.GetDirectoryName(
    AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar))!;
var configPath = Path.Combine(baseDir, "config.json");
var config = File.Exists(configPath)
    ? JsonSerializer.Deserialize<Config>(File.ReadAllText(configPath)) ?? new()
    : new();

if (args.Length == 0) return Error("Usage: notifications <on-submit|notify|on-end|trigger|editor>");

try
{
    return args[0] switch
    {
        "on-submit" => OnSubmit(),
        "notify" => Notify(args.Length > 1 ? args[1] : "notification"),
        "on-end" => OnEnd(),
        "trigger" => Trigger(args.Length > 1 ? args[1] : ""),
        "editor" => OpenEditor(args.Length > 1 ? args[1] : ""),
        _ => Error($"Unknown: {args[0]}")
    };
}
catch (Exception e) { return Error(e.Message); }

// ═══════════════════════════════════════
// on-submit — called on every user message (UserPromptSubmit hook, async: true)
//
// 1. Reads session_id from Claude Code's JSON on stdin
// 2. Walks the process tree to find Windows Terminal PID + Claude PID
// 3. Finds the currently selected WT tab via UI Automation (STA thread required)
// 4. Saves everything to a temp file for notify to read later
// 5. Runs the focus watcher loop inline (async: true means Claude doesn't wait)
//
// Because this process is a child of WT's process tree (bash → claude → WT),
// UI Automation tab selection (SelectionItemPattern.Select()) works directly.
// No WMI/VBS detachment needed — async: true prevents blocking Claude.
// ═══════════════════════════════════════

int OnSubmit()
{
    var json = ReadStdin();
    if (json == null) return 1;

    var sid = json.Value.GetProperty("session_id").GetString()!;
    var cwd = Directory.GetCurrentDirectory();
    var ts = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    // Walk up the process tree: this exe → bash → claude → pwsh → WindowsTerminal
    int wtPid = 0, claudePid = 0;
    WalkParents(p =>
    {
        if (p.ProcessName == "claude") claudePid = p.Id;
        if (p.ProcessName == "WindowsTerminal") { wtPid = p.Id; return false; }
        return true;
    });

    // Not in Windows Terminal (running in IDE like Zed) — skip everything
    if (wtPid == 0) return 0;

    // Find the selected tab's RuntimeId + name via UI Automation.
    // Must run on an STA thread — UI Automation uses COM which needs
    // Single-Threaded Apartment. Console apps default to MTA.
    string tabRid = "", tabName = "";
    var staThread = new Thread(() =>
    {
        var (rid, raw) = FindSelectedTab(wtPid);
        tabRid = rid;
        // Strip spinner characters (⠐⠑⠒ etc.) that Claude Code prepends to tab titles
        tabName = Regex.Replace(raw, @"^[\u2800-\u28FF\s]+", "");
    });
    staThread.SetApartmentState(ApartmentState.STA);
    staThread.Start();
    staThread.Join();

    // Save session state: timestamp|wtPid|claudePid|cwd|tabRuntimeId|tabName
    TimerWrite(sid, $"{ts}|{wtPid}|{claudePid}|{cwd}|{tabRid}|{tabName}");

    // Save our PID so the next on-submit call can kill us.
    File.WriteAllText(WatcherPidPath(sid), Environment.ProcessId.ToString());

    // Run the focus watcher loop directly. With async: true on the hook,
    // this process stays alive without blocking Claude. It's in WT's process
    // tree so UI Automation tab selection works.
    WatchForTrigger(sid, wtPid, claudePid, tabRid);

    return 0;
}

// ═══════════════════════════════════════
// notify — called when Claude needs input (Notification hook) or finishes (Stop hook)
//
// 1. Reads session state from the temp file written by on-submit
// 2. Calculates elapsed time since last user message
// 3. Builds toast XML with project name, message, elapsed time, icon, and buttons
// 4. Shows the toast via WinRT ToastNotificationManager
// ═══════════════════════════════════════

int Notify(string hookEvent)
{
    var json = ReadStdin();
    if (json == null) return 1;

    var sid = json.Value.GetProperty("session_id").GetString()!;
    var jsonCwd = json.Value.TryGetProperty("cwd", out var c) ? c.GetString() : null;
    var timer = TimerRead(sid);
    if (timer == null) return 0;

    var wtPid = int.Parse(timer[1]);
    if (wtPid == 0) return 0; // IDE, skip

    var cwd = timer[3];
    var dir = Path.GetFileName(jsonCwd ?? cwd);
    var tabName = timer.Length > 5 ? timer[5] : dir;

    // Elapsed time since last user message
    var ms = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - long.Parse(timer[0]);
    var s = ms / 1000;
    var elapsed = s < 1 ? "(<1s)" : s < 60 ? $"({s}s)" : s < 3600 ? $"({s/60}m {s%60}s)" : $"({s/3600}h {s/60%60}m)";

    // Message and icon from config (with defaults)
    var message = hookEvent == "stop" ? (config.Messages?.Stop ?? "Task completed")
                                      : (config.Messages?.Notification ?? "Claude needs your input");
    var iconFile = hookEvent == "stop" ? (config.Icons?.Stop ?? "icons/stop.png")
                                       : (config.Icons?.Notification ?? "icons/notification.png");
    var iconPath = Path.GetFullPath(Path.Combine(baseDir, iconFile));

    // Protocol URIs for button actions
    var focusUri = $"claude-focus://{sid}";
    var editorUri = !string.IsNullOrEmpty(config.Editor) ? $"claude-editor://{cwd.Replace('\\', '/')}" : "";
    var editorLabel = !string.IsNullOrEmpty(config.Editor) ? "Open in " + char.ToUpper(config.Editor[0]) + config.Editor[1..] : "";

    // Build toast XML (Microsoft toast notification schema)
    // - launch: protocol URI opened when notification body is clicked
    // - appLogoOverride: icon shown next to the text
    // - action: button with protocol activation
    var xml = $@"<toast launch=""{Esc(focusUri)}"" activationType=""protocol"">
  <visual><binding template=""ToastGeneric"">
    <text>{Esc(dir)}</text>
    <text>{Esc(message)} {Esc(elapsed)}</text>
    {(File.Exists(iconPath) ? $@"<image placement=""appLogoOverride"" src=""file:///{iconPath.Replace('\\', '/')}"" />" : "")}
  </binding></visual>
  <actions>
    <action content=""Focus Terminal"" arguments=""{Esc(focusUri)}"" activationType=""protocol"" />
    {(editorUri != "" ? $@"<action content=""{Esc(editorLabel)}"" arguments=""{Esc(editorUri)}"" activationType=""protocol"" />" : "")}
  </actions>
</toast>";

    var doc = new XmlDocument();
    doc.LoadXml(xml);
    var toast = new ToastNotification(doc) { Tag = sid.Length > 64 ? sid[..64] : sid };
    ToastNotificationManager.CreateToastNotifier(AUMID).Show(toast);
    return 0;
}

// ═══════════════════════════════════════
// on-end — called when Claude session ends (SessionEnd hook)
// ═══════════════════════════════════════

int OnEnd()
{
    var json = ReadStdin();
    if (json == null) return 1;
    var sid = json.Value.GetProperty("session_id").GetString()!;
    KillWatchers(sid);
    TimerDelete(sid);
    TriggerDelete(sid);
    WatcherPidDelete(sid);
    return 0;
}

// ═══════════════════════════════════════
// trigger — protocol handler for claude-focus://
//
// Called by Windows when the "Focus Terminal" button is clicked on a toast.
// Creates a trigger file that the watcher polls for.
// ═══════════════════════════════════════

int Trigger(string uri)
{
    var sid = uri.Replace("claude-focus://", "").TrimEnd('/');
    if (string.IsNullOrEmpty(sid)) return 1;
    File.WriteAllText(TriggerPath(sid), "");
    return 0;
}

// ═══════════════════════════════════════
// editor — protocol handler for claude-editor://
//
// Called by Windows when the "Open in Editor" button is clicked on a toast.
// Launches the configured editor with the project directory.
// ═══════════════════════════════════════

int OpenEditor(string uri)
{
    var path = uri.Replace("claude-editor://", "").TrimEnd('/').Replace('/', '\\');
    if (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(config.Editor)) return 1;
    if (!Directory.Exists(path) && !File.Exists(path)) return 1;
    Process.Start(new ProcessStartInfo(config.Editor, $"\"{path}\"")
    {
        WorkingDirectory = Directory.Exists(path) ? path : Path.GetDirectoryName(path),
        UseShellExecute = false
    });
    return 0;
}

// ═══════════════════════════════════════
// Win32 + UI Automation
// ═══════════════════════════════════════

[DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

/// Focus watcher loop — polls for trigger file, focuses WT window and selects tab.
/// Runs on an STA thread (required for UI Automation COM calls).
/// Exits when WT or Claude process dies.
static void WatchForTrigger(string sid, int wtPid, int claudePid, string tabRid)
{
    var triggerPath = TriggerPath(sid);
    long lastFocus = 0;

    var staThread = new Thread(() =>
    {
        while (true)
        {
            // Exit if WT or Claude process is gone
            try { Process.GetProcessById(wtPid); } catch { return; }
            if (claudePid != 0)
                try { Process.GetProcessById(claudePid); } catch { return; }

            if (File.Exists(triggerPath))
            {
                try { File.Delete(triggerPath); } catch { }

                // Debounce: skip if focused within last 2 seconds
                var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                if (now - lastFocus < 2000) { Thread.Sleep(200); continue; }
                lastFocus = now;

                try
                {
                    var pCond = new PropertyCondition(AutomationElement.ProcessIdProperty, wtPid);
                    var tCond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem);

                    foreach (AutomationElement win in AutomationElement.RootElement.FindAll(TreeScope.Children, pCond))
                    {
                        foreach (AutomationElement tab in win.FindAll(TreeScope.Descendants, tCond))
                        {
                            if (string.IsNullOrEmpty(tabRid) || string.Join(",", tab.GetRuntimeId()) == tabRid)
                            {
                                var hwnd = (IntPtr)win.Current.NativeWindowHandle;
                                ShowWindow(hwnd, 9);  // SW_RESTORE
                                SetForegroundWindow(hwnd);

                                if (!string.IsNullOrEmpty(tabRid))
                                {
                                    Thread.Sleep(200);
                                    ((SelectionItemPattern)tab.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
                                }
                                goto focused;
                            }
                        }
                    }
                    focused:;
                }
                catch { }
            }

            Thread.Sleep(200);
        }
    });
    staThread.SetApartmentState(ApartmentState.STA);
    staThread.Start();
    staThread.Join();
}

// ═══════════════════════════════════════
// Helpers
// ═══════════════════════════════════════

/// Escapes special XML characters for toast XML attributes/content.
static string Esc(string s) => s.Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;").Replace("\"","&quot;");

/// Reads and parses JSON from stdin (piped by Claude Code hooks).
static JsonElement? ReadStdin()
{
    try { return JsonDocument.Parse(Console.In.ReadToEnd()).RootElement; } catch { return null; }
}

/// Walks the process tree from the current process upward, calling fn for each ancestor.
/// fn returns true to continue walking, false to stop.
static void WalkParents(Func<Process, bool> fn)
{
    var p = Process.GetCurrentProcess();
    while (p != null)
    {
        try
        {
            using var q = new System.Management.ManagementObjectSearcher(
                $"SELECT ParentProcessId FROM Win32_Process WHERE ProcessId = {p.Id}");
            var r = q.Get().Cast<System.Management.ManagementObject>().FirstOrDefault();
            if (r == null) break;
            p = Process.GetProcessById((int)(uint)r["ParentProcessId"]);
            if (!fn(p)) break;
        }
        catch { break; }
    }
}

/// Finds the currently selected tab in Windows Terminal via UI Automation.
/// Returns (RuntimeId, TabName). RuntimeId uniquely identifies the tab across reorders.
static (string rid, string name) FindSelectedTab(int wtPid)
{
    try
    {
        var pCond = new PropertyCondition(AutomationElement.ProcessIdProperty, wtPid);
        var tCond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem);
        foreach (AutomationElement win in AutomationElement.RootElement.FindAll(TreeScope.Children, pCond))
            foreach (AutomationElement tab in win.FindAll(TreeScope.Descendants, tCond))
                if (tab.GetCurrentPattern(SelectionItemPattern.Pattern) is SelectionItemPattern s && s.Current.IsSelected)
                    return (string.Join(",", tab.GetRuntimeId()), tab.Current.Name);
    }
    catch { }
    return ("", "");
}

/// Kills the previous watcher process for a given session ID (if any).
/// Watcher PID is stored in a temp file by the watcher itself.
static void KillWatchers(string sid)
{
    var path = WatcherPidPath(sid);
    if (!File.Exists(path)) return;
    try
    {
        var pid = int.Parse(File.ReadAllText(path).Trim());
        if (pid != Environment.ProcessId)
            Process.GetProcessById(pid).Kill();
    }
    catch { }
    try { File.Delete(path); } catch { }
}

// Timer file: stores session state as pipe-delimited values in %TEMP%.
// Format: timestamp|wtPid|claudePid|cwd|tabRuntimeId|tabName
static string TimerPath(string sid) => Path.Combine(Path.GetTempPath(), $"claude-timer-{sid}.txt");
static void TimerWrite(string sid, string data) => File.WriteAllText(TimerPath(sid), data);
static string[]? TimerRead(string sid) { var p = TimerPath(sid); return File.Exists(p) ? File.ReadAllText(p).Split('|', 6) : null; }
static void TimerDelete(string sid) { try { File.Delete(TimerPath(sid)); } catch { } }

// Trigger file: empty file in %TEMP%. Created by the protocol handler when the user
// clicks "Focus Terminal". The watcher polls for it every 200ms.
static string TriggerPath(string sid) => Path.Combine(Path.GetTempPath(), $"claude-focus-trigger-{sid}");
static void TriggerDelete(string sid) { try { File.Delete(TriggerPath(sid)); } catch { } }

// Watcher PID file: stores the PID of the on-submit watcher process so the next
// on-submit call (or on-end) can kill it.
static string WatcherPidPath(string sid) => Path.Combine(Path.GetTempPath(), $"claude-watcher-{sid}.txt");
static void WatcherPidDelete(string sid) { try { File.Delete(WatcherPidPath(sid)); } catch { } }

static int Error(string msg) { Console.Error.WriteLine(msg); return 1; }

// ═══════════════════════════════════════
// Config — read from config.json
// ═══════════════════════════════════════

record Config
{
    [JsonPropertyName("editor")] public string? Editor { get; init; }
    [JsonPropertyName("messages")] public MessagesConfig? Messages { get; init; }
    [JsonPropertyName("icons")] public IconsConfig? Icons { get; init; }
}
record MessagesConfig
{
    [JsonPropertyName("notification")] public string? Notification { get; init; }
    [JsonPropertyName("stop")] public string? Stop { get; init; }
}
record IconsConfig
{
    [JsonPropertyName("notification")] public string? Notification { get; init; }
    [JsonPropertyName("stop")] public string? Stop { get; init; }
}
