// Prevents console window flash when launched by protocol handlers or toast clicks.
// Stdin/stdout still work when piped by Claude Code's hook system.
#![windows_subsystem = "windows"]

// CC Hooks — Windows notification system
//
// Single native exe (~350KB) called by Claude Code hooks (settings.json).
//
// Subcommands (each invoked as a separate process by hook events):
//   on-submit  — UserPromptSubmit hook (async: true). Captures session state
//                (WT PID, tab ID, cwd, timestamp) then enters a focus watcher
//                loop. Runs in WT's process tree so UI Automation works.
//   notify     — Notification/Stop hook. Shows a WinRT toast with project name,
//                elapsed time, and buttons for terminal focus + editor launch.
//   on-end     — SessionEnd hook. Kills the watcher, cleans up temp files.
//   trigger    — Protocol handler for claude-focus://. Creates a trigger file
//                that the watcher polls for (toast "Focus Terminal" button).
//   editor     — Protocol handler for claude-editor://. Launches the configured
//                editor with the project directory (toast "Open in Editor" button).
//   install    — Merges hook config into ~/.claude/settings.json.
//   uninstall  — Removes hooks from settings.json, cleans up temp files.
//
// Config: ../config.json (relative to bin/). See config.json.example.
// Icons:  ../icons/ (gitignored). PNG for toast body, ICO for attribution bar.
// State:  %TEMP%/claude-timer-{session_id}.txt (pipe-delimited session data)
//         %TEMP%/claude-watcher-{session_id}.txt (watcher PID for cleanup)
//         %TEMP%/claude-focus-trigger-{session_id} (empty file, IPC with watcher)

use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::Read;
use std::mem::size_of;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use serde::Deserialize;
use windows::core::*;
use windows::Win32::System::SystemInformation::GetTickCount;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
use windows::Data::Xml::Dom::XmlDocument;
use windows::UI::Notifications::*;
use windows::Win32::Foundation::*;
use windows::Win32::System::Com::*;
use windows::Win32::System::Diagnostics::ToolHelp::*;
use windows::Win32::System::Ole::*;
use windows::Win32::System::Threading::*;
use windows::Win32::System::Variant::VARIANT;
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::WindowsAndMessaging::*;

// Application User Model ID — registered in HKLM by install.ps1.
// Windows uses this to associate toasts with the app's display name and icon.
const AUMID: &str = "ClaudeCode.Hooks";

// ═══════════════════════════════════════
// Config — read from config.json
// ═══════════════════════════════════════

#[derive(Deserialize, Default)]
struct Config {
    editor: Option<String>,
    desktop: Option<bool>,   // false = skip desktop notification (webhook-only mode)
    sound: Option<String>,   // "default", sound name, or "" to disable
    messages: Option<Messages>,
    icons: Option<Icons>,
    webhook: Option<WebhookConfig>,
}

#[derive(Deserialize, Default)]
struct Messages {
    notification: Option<String>,
    permission: Option<String>,
    elicitation: Option<String>,
    idle: Option<String>,
    stop: Option<String>,
}

#[derive(Deserialize, Default)]
struct Icons {
    notification: Option<String>,
    permission: Option<String>,
    elicitation: Option<String>,
    idle: Option<String>,
    stop: Option<String>,
}

#[derive(Deserialize, Default)]
struct WebhookConfig {
    enabled: Option<bool>,    // false = disable webhook without removing config
    url: Option<String>,
    idle_minutes: Option<u32>,
    payload: Option<String>,  // Path to JSON template file
}

// ═══════════════════════════════════════
// Entry point
// ═══════════════════════════════════════

fn main() -> ExitCode {
    let exe = env::current_exe().unwrap_or_default();
    // Find project root by walking up from exe looking for config.json.
    // Works from both bin/ and target/release/.
    let base_dir = {
        let mut dir = exe.parent().unwrap_or(Path::new("."));
        loop {
            if dir.join("config.json").exists() { break dir.to_path_buf(); }
            match dir.parent() {
                Some(p) => dir = p,
                None => break exe.parent().unwrap_or(Path::new(".")).to_path_buf(),
            }
        }
    };

    let config: Config = fs::read_to_string(base_dir.join("config.json"))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();

    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: notifications <on-submit|notify|on-end|trigger|editor|install|uninstall>");
        return ExitCode::from(1);
    }

    let code = match args[1].as_str() {
        "on-submit" => on_submit(&base_dir),
        "notify" => notify(args.get(2).map(|s| s.as_str()).unwrap_or("notification"), &base_dir, &config),
        "on-end" => on_end(),
        "trigger" => trigger(args.get(2).map(|s| s.as_str()).unwrap_or("")),
        "editor" => open_editor(args.get(2).map(|s| s.as_str()).unwrap_or(""), &config),
        "install" => install_hooks(&exe),
        "uninstall" => uninstall_hooks(),
        other => { eprintln!("Unknown: {other}"); 1 }
    };

    ExitCode::from(code as u8)
}

// ═══════════════════════════════════════
// on-submit — UserPromptSubmit hook (async: true)
//
// Saves session state, then enters the focus watcher loop. With async: true,
// Claude doesn't wait for this process to exit. Since we're spawned inside
// WT's process tree (bash → claude → WT), UI Automation tab selection works
// directly — no detached process or polling hack needed.
// ═══════════════════════════════════════

fn on_submit(_base_dir: &Path) -> i32 {
    let json = match read_stdin() { Some(j) => j, None => return 1 };
    let sid = match json.get("session_id").and_then(|v| v.as_str()) { Some(s) => s.to_string(), None => return 1 };

    // Kill previous watcher for this session
    kill_watcher(&sid);

    let cwd = json.get("cwd").and_then(|v| v.as_str()).map(String::from)
        .unwrap_or_else(|| env::current_dir().unwrap_or_default().to_string_lossy().to_string());
    let ts = now_ms();

    let (wt_pid, claude_pid) = find_ancestors();
    if wt_pid == 0 { return 0; } // Not in Windows Terminal (IDE like Zed)

    // Find selected tab on STA thread (UI Automation requires COM STA)
    let wt = wt_pid;
    let (tab_rid, tab_name) = run_on_sta(move || find_selected_tab(wt))
        .map(|(rid, raw)| {
            // Strip spinner characters (braille patterns U+2800..U+28FF) from tab title
            let name = raw.trim_start_matches(|c: char| ('\u{2800}'..='\u{28FF}').contains(&c) || c == ' ').to_string();
            (rid, name)
        })
        .unwrap_or_default();

    // Save session state: timestamp|wtPid|claudePid|cwd|tabRuntimeId|tabName
    timer_write(&sid, &format!("{ts}|{wt_pid}|{claude_pid}|{cwd}|{tab_rid}|{tab_name}"));

    // Save our PID so the next on-submit call can kill us
    let _ = fs::write(watcher_pid_path(&sid), std::process::id().to_string());

    // Run watcher loop (async: true on hook means Claude won't wait)
    watch_for_trigger(&sid, wt_pid, claude_pid, &tab_rid);

    0
}

// ═══════════════════════════════════════
// notify — Notification/Stop hook
//
// Reads session state from the timer file, calculates elapsed time since
// the last user message, and shows a WinRT toast with project name, message,
// icon, and action buttons (Focus Terminal + Open in Editor).
// ═══════════════════════════════════════

fn notify(hook_event: &str, base_dir: &Path, config: &Config) -> i32 {
    let json = match read_stdin() { Some(j) => j, None => return 1 };
    let sid = match json.get("session_id").and_then(|v| v.as_str()) { Some(s) => s.to_string(), None => return 1 };
    let json_cwd = json.get("cwd").and_then(|v| v.as_str()).map(String::from);
    let notification_type = json.get("notification_type").and_then(|v| v.as_str()).unwrap_or("");

    // Skip auth_success — redundant, user just authenticated
    if notification_type == "auth_success" { return 0; }

    let timer = match timer_read(&sid) { Some(t) => t, None => return 0 };
    let wt_pid: u32 = timer.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);
    if wt_pid == 0 { return 0; } // IDE, skip

    let cwd = json_cwd.as_deref()
        .or(timer.get(3).map(|s| s.as_str())).unwrap_or_default();
    let dir = Path::new(cwd).file_name().unwrap_or_default().to_string_lossy().to_string();

    // Elapsed time since last user message
    let start_ms: u64 = timer.first().and_then(|s| s.parse().ok()).unwrap_or(0);
    let s = (now_ms().saturating_sub(start_ms)) / 1000;
    let elapsed = if s < 1 { "(<1s)".into() }
        else if s < 60 { format!("({s}s)") }
        else if s < 3600 { format!("({}m {}s)", s / 60, s % 60) }
        else { format!("({}h {}m)", s / 3600, s / 60 % 60) };

    let message = if hook_event == "stop" {
        config.messages.as_ref().and_then(|m| m.stop.as_deref()).unwrap_or("Task completed")
    } else {
        match notification_type {
            "permission_prompt" => config.messages.as_ref().and_then(|m| m.permission.as_deref()).unwrap_or("Claude needs permission"),
            "elicitation_dialog" => config.messages.as_ref().and_then(|m| m.elicitation.as_deref()).unwrap_or("Action required"),
            "idle_prompt" => config.messages.as_ref().and_then(|m| m.idle.as_deref()).unwrap_or("Claude is waiting"),
            _ => config.messages.as_ref().and_then(|m| m.notification.as_deref()).unwrap_or("Claude needs your input"),
        }
    };

    let icon_file = if hook_event == "stop" {
        config.icons.as_ref().and_then(|i| i.stop.as_deref()).unwrap_or("icons/stop.png")
    } else {
        let type_icon = match notification_type {
            "permission_prompt" => config.icons.as_ref().and_then(|i| i.permission.as_deref()),
            "elicitation_dialog" => config.icons.as_ref().and_then(|i| i.elicitation.as_deref()),
            "idle_prompt" => config.icons.as_ref().and_then(|i| i.idle.as_deref()),
            _ => None,
        };
        type_icon.or_else(|| config.icons.as_ref().and_then(|i| i.notification.as_deref()))
            .unwrap_or("icons/notification.png")
    };
    let icon_path = base_dir.join(icon_file);
    let icon_str = icon_path.to_string_lossy().replace('\\', "/");

    let focus_uri = format!("claude-focus://{sid}");
    let (editor_uri, editor_label) = match config.editor.as_deref() {
        Some(ed) if !ed.is_empty() => (
            format!("claude-editor://{}", cwd.replace('\\', "/")),
            format!("Open in {}{}", ed[..1].to_uppercase(), &ed[1..]),
        ),
        _ => (String::new(), String::new()),
    };

    let icon_xml = if icon_path.exists() {
        format!(r#"<image placement="appLogoOverride" src="file:///{icon_str}" />"#)
    } else { String::new() };

    let editor_xml = if !editor_uri.is_empty() {
        format!(r#"<action content="{}" arguments="{}" activationType="protocol" />"#,
            esc(&editor_label), esc(&editor_uri))
    } else { String::new() };

    let audio_xml = match config.sound.as_deref() {
        Some("") => r#"<audio silent="true" />"#.to_string(),
        Some("default") | None => String::new(),
        Some(name) => format!(r#"<audio src="ms-winsoundevent:Notification.{}" />"#, esc(name)),
    };

    let xml = format!(
r#"<toast launch="{focus}" activationType="protocol">
  <visual><binding template="ToastGeneric">
    <text>{dir}</text>
    <text>{msg} {elapsed}</text>
    {icon}
  </binding></visual>
  <actions>
    <action content="Focus Terminal" arguments="{focus}" activationType="protocol" />
    {editor}
  </actions>
  {audio}
</toast>"#,
        focus = esc(&focus_uri), dir = esc(&dir), msg = esc(message),
        elapsed = esc(&elapsed), icon = icon_xml, editor = editor_xml,
        audio = audio_xml,
    );

    let toast_result = if config.desktop.unwrap_or(true) {
        show_toast(&xml, &sid)
    } else { 0 };

    // Send webhook after toast (only when AFK, or always if idle_minutes == 0)
    // auth_success is already skipped above
    if let Some(ref webhook) = config.webhook {
        if webhook.enabled.unwrap_or(true) {
        if let (Some(ref url), Some(ref payload_file)) = (&webhook.url, &webhook.payload) {
            if !url.is_empty() && !payload_file.is_empty() {
                let idle_minutes = webhook.idle_minutes.unwrap_or(15);
                let send = idle_minutes == 0
                    || (s >= idle_minutes as u64 * 60 && is_afk(idle_minutes));
                if send {
                    let url = url.clone();
                    let template_path = base_dir.join(payload_file);
                    let dir = dir.clone();
                    let elapsed = elapsed.clone();
                    let message = message.to_string();
                    let event = hook_event.to_string();
                    let ntype = notification_type.to_string();
                    let handle = thread::spawn(move || {
                        let vars = [
                            ("title", dir.as_str()),
                            ("message", message.as_str()),
                            ("elapsed", elapsed.as_str()),
                            ("project", dir.as_str()),
                            ("event", event.as_str()),
                            ("notification_type", ntype.as_str()),
                        ];
                        send_webhook(&url, &template_path, &vars);
                    });
                    let _ = handle.join();
                }
            }
        }
        }
    }

    toast_result
}

fn show_toast(xml_str: &str, sid: &str) -> i32 {
    let doc = XmlDocument::new().ok();
    let Some(doc) = doc else { return 1 };
    if doc.LoadXml(&HSTRING::from(xml_str)).is_err() { return 1; }

    let Ok(toast) = ToastNotification::CreateToastNotification(&doc) else { return 1 };
    let tag = if sid.len() > 64 { &sid[..64] } else { sid };
    let _ = toast.SetTag(&HSTRING::from(tag));

    let Ok(notifier) = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(AUMID)) else { return 1 };
    if notifier.Show(&toast).is_err() { return 1; }
    0
}

// ═══════════════════════════════════════
// on-end — kills watcher, cleans up temp files
// ═══════════════════════════════════════

fn on_end() -> i32 {
    let json = match read_stdin() { Some(j) => j, None => return 1 };
    let sid = match json.get("session_id").and_then(|v| v.as_str()) { Some(s) => s, None => return 1 };
    kill_watcher(sid);
    timer_delete(sid);
    trigger_delete(sid);
    watcher_pid_delete(sid);
    0
}

// ═══════════════════════════════════════
// install / uninstall — manages ~/.claude/settings.json
// ═══════════════════════════════════════

fn settings_path() -> PathBuf {
    let home = env::var("USERPROFILE").unwrap_or_else(|_| env::var("HOME").unwrap_or_default());
    PathBuf::from(home).join(".claude").join("settings.json")
}

fn install_hooks(exe: &Path) -> i32 {
    let path = settings_path();
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let mut settings: serde_json::Map<String, serde_json::Value> = fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();

    let exe_str = exe.to_string_lossy().replace('\\', "/");

    let hook_entry = |cmd: &str, async_flag: bool| -> serde_json::Value {
        let mut hook = serde_json::json!({
            "type": "command",
            "command": format!("{exe_str} {cmd}")
        });
        if async_flag {
            hook.as_object_mut().unwrap().insert("async".into(), serde_json::Value::Bool(true));
        }
        serde_json::json!([{"matcher": "", "hooks": [hook]}])
    };

    let mut hooks: serde_json::Map<String, serde_json::Value> = settings
        .get("hooks")
        .and_then(|h| h.as_object().cloned())
        .unwrap_or_default();

    hooks.insert("UserPromptSubmit".into(), hook_entry("on-submit", true));
    hooks.insert("Notification".into(), hook_entry("notify notification", false));
    hooks.insert("Stop".into(), hook_entry("notify stop", false));
    hooks.insert("SessionEnd".into(), hook_entry("on-end", false));

    settings.insert("hooks".into(), serde_json::Value::Object(hooks));

    let Ok(json) = serde_json::to_string_pretty(&settings) else { return 1 };
    if fs::write(&path, json).is_err() { return 1; }

    eprintln!("Updated {}", path.display());
    0
}

fn uninstall_hooks() -> i32 {
    // Clean temp files
    if let Ok(entries) = fs::read_dir(env::temp_dir()) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("claude-timer-") || name.starts_with("claude-watcher-") || name.starts_with("claude-focus-trigger-") {
                let _ = fs::remove_file(entry.path());
            }
        }
    }

    // Remove hooks from settings.json
    let path = settings_path();
    let Ok(content) = fs::read_to_string(&path) else {
        eprintln!("Uninstalled");
        return 0;
    };
    let Ok(mut settings) = serde_json::from_str::<serde_json::Map<String, serde_json::Value>>(&content) else {
        eprintln!("Uninstalled");
        return 0;
    };

    if let Some(hooks_val) = settings.get_mut("hooks") {
        if let Some(hooks) = hooks_val.as_object_mut() {
            for event in &["UserPromptSubmit", "Notification", "Stop", "SessionEnd"] {
                if let Some(entries) = hooks.get_mut(*event) {
                    if let Some(arr) = entries.as_array_mut() {
                        arr.retain(|entry| {
                            let hook_list = entry.get("hooks").and_then(|h| h.as_array());
                            !hook_list.map_or(false, |list| {
                                list.iter().any(|h| {
                                    h.get("command").and_then(|c| c.as_str())
                                        .map_or(false, |c| c.contains("notifications"))
                                })
                            })
                        });
                        if arr.is_empty() { hooks.remove(*event); }
                    }
                }
            }
            if hooks.is_empty() { settings.remove("hooks"); }
        }
    }

    if let Ok(json) = serde_json::to_string_pretty(&settings) {
        let _ = fs::write(&path, json);
    }

    eprintln!("Uninstalled");
    0
}

// ═══════════════════════════════════════
// trigger — protocol handler for claude-focus://
//
// Called by Windows when the "Focus Terminal" button is clicked on a toast.
// Creates a trigger file that the watcher polls for.
// ═══════════════════════════════════════

fn trigger(uri: &str) -> i32 {
    let sid = uri.replace("claude-focus://", "");
    let sid = sid.trim_end_matches('/');
    if sid.is_empty() { return 1; }
    let _ = fs::write(trigger_path(sid), "");
    0
}

// ═══════════════════════════════════════
// editor — protocol handler for claude-editor://
//
// Called by Windows when the "Open in Editor" button is clicked on a toast.
// Launches the configured editor with the project directory.
// ═══════════════════════════════════════

fn open_editor(uri: &str, config: &Config) -> i32 {
    let path = uri.replace("claude-editor://", "").trim_end_matches('/').replace('/', "\\");
    let editor = match config.editor.as_deref() { Some(e) if !e.is_empty() => e, _ => return 1 };
    if path.is_empty() { return 1; }
    let p = Path::new(&path);
    if !p.exists() { return 1; }
    let work_dir = if p.is_dir() { p } else { p.parent().unwrap_or(Path::new(".")) };
    let _ = std::process::Command::new(editor).arg(&path).current_dir(work_dir).spawn();
    0
}

// ═══════════════════════════════════════
// Focus watcher
//
// Polls %TEMP% for a trigger file (created by the claude-focus:// protocol
// handler when the user clicks "Focus Terminal" on a toast). When found,
// uses UI Automation to focus the WT window and select the correct tab.
// Exits when WT or Claude process dies. Debounces within 2 seconds.
// ═══════════════════════════════════════

fn watch_for_trigger(sid: &str, wt_pid: u32, claude_pid: u32, tab_rid: &str) {
    let sid = sid.to_string();
    let tab_rid = tab_rid.to_string();

    // Run on STA thread (required for UI Automation COM calls)
    let _ = run_on_sta(move || {
        let trigger = trigger_path(&sid);
        let mut last_focus: u64 = 0;

        loop {
            if !process_alive(wt_pid) || (claude_pid != 0 && !process_alive(claude_pid)) {
                // Parent died without SessionEnd firing — clean up our own files
                // so they don't linger as orphans in %TEMP%.
                timer_delete(&sid);
                trigger_delete(&sid);
                watcher_pid_delete(&sid);
                return;
            }

            if trigger.exists() {
                let _ = fs::remove_file(&trigger);

                // Debounce: skip if focused within last 2 seconds
                let now = now_ms();
                if now - last_focus < 2000 { thread::sleep(Duration::from_millis(200)); continue; }
                last_focus = now;

                focus_terminal(wt_pid, &tab_rid);
            }

            thread::sleep(Duration::from_millis(200));
        }
    });
}

fn focus_terminal(wt_pid: u32, tab_rid: &str) {
    unsafe {
        let Ok(auto) = create_automation() else { return };
        let Ok(root) = auto.GetRootElement() else { return };

        let Ok(pid_cond) = auto.CreatePropertyCondition(
            UIA_ProcessIdPropertyId, &VARIANT::from(wt_pid as i32),
        ) else { return };
        let Ok(tab_cond) = auto.CreatePropertyCondition(
            UIA_ControlTypePropertyId, &VARIANT::from(UIA_TabItemControlTypeId.0),
        ) else { return };

        let Ok(windows) = root.FindAll(TreeScope_Children, &pid_cond) else { return };
        for i in 0..windows.Length().unwrap_or(0) {
            let Ok(win) = windows.GetElement(i) else { continue };
            let Ok(tabs) = win.FindAll(TreeScope_Descendants, &tab_cond) else { continue };

            for j in 0..tabs.Length().unwrap_or(0) {
                let Ok(tab) = tabs.GetElement(j) else { continue };

                let rid = get_runtime_id(&tab);
                if !tab_rid.is_empty() && rid != tab_rid { continue; }

                let hwnd = HWND(win.CurrentNativeWindowHandle().unwrap_or_default().0);
                if IsIconic(hwnd).as_bool() {
                    // Only use ShowWindow for minimized — it's needed to restore.
                    // For all other states (normal, maximized, snapped), skip
                    // ShowWindow to preserve window geometry and snap layout.
                    let _ = ShowWindow(hwnd, SW_RESTORE);
                }
                // Attach to foreground thread to bypass SetForegroundWindow restrictions
                let fg = GetForegroundWindow();
                let fg_thread = GetWindowThreadProcessId(fg, None);
                let our_thread = GetCurrentThreadId();
                let attached = fg_thread != 0 && fg_thread != our_thread
                    && AttachThreadInput(our_thread, fg_thread, true).as_bool();
                let _ = SetForegroundWindow(hwnd);
                if attached {
                    let _ = AttachThreadInput(our_thread, fg_thread, false);
                }

                if !tab_rid.is_empty() {
                    thread::sleep(Duration::from_millis(200));
                    if let Ok(pattern) = tab.GetCurrentPattern(UIA_SelectionItemPatternId) {
                        if let Ok(sip) = pattern.cast::<IUIAutomationSelectionItemPattern>() {
                            let _ = sip.Select();
                        }
                    }
                }
                return;
            }
        }
    }
}

// ═══════════════════════════════════════
// Process helpers
//
// Uses CreateToolhelp32Snapshot to walk the process tree (lighter than WMI).
// Finds WT and Claude PIDs by walking from our PID upward through parents.
// ═══════════════════════════════════════

fn find_ancestors() -> (u32, u32) {
    let (mut wt_pid, mut claude_pid) = (0u32, 0u32);
    let procs = snapshot_processes();

    // Walk from current process upward through parent chain
    let mut pid = std::process::id();
    loop {
        let Some((parent, _)) = procs.get(&pid) else { break };
        pid = *parent;
        let Some((_, name)) = procs.get(&pid) else { break };
        let base = name.strip_suffix(".exe").unwrap_or(name);
        if base.eq_ignore_ascii_case("claude") { claude_pid = pid; }
        if base.eq_ignore_ascii_case("WindowsTerminal") { wt_pid = pid; break; }
    }

    (wt_pid, claude_pid)
}

fn snapshot_processes() -> HashMap<u32, (u32, String)> {
    let mut map = HashMap::new();
    unsafe {
        let Ok(snap) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else { return map };
        let mut pe = PROCESSENTRY32W { dwSize: size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };

        if Process32FirstW(snap, &mut pe).is_ok() {
            loop {
                let len = pe.szExeFile.iter().position(|&c| c == 0).unwrap_or(pe.szExeFile.len());
                let name = String::from_utf16_lossy(&pe.szExeFile[..len]);
                map.insert(pe.th32ProcessID, (pe.th32ParentProcessID, name));
                if Process32NextW(snap, &mut pe).is_err() { break; }
            }
        }
        let _ = CloseHandle(snap);
    }
    map
}

fn process_alive(pid: u32) -> bool {
    unsafe {
        let Ok(handle) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return false };
        let mut code = 0u32;
        let alive = GetExitCodeProcess(handle, &mut code).is_ok() && code == 259; // STILL_ACTIVE
        let _ = CloseHandle(handle);
        alive
    }
}

fn kill_watcher(sid: &str) {
    let path = watcher_pid_path(sid);
    let Ok(content) = fs::read_to_string(&path) else { return };
    let Ok(pid) = content.trim().parse::<u32>() else { return };
    if pid == std::process::id() { return; }
    unsafe {
        if let Ok(h) = OpenProcess(PROCESS_TERMINATE, false, pid) {
            let _ = TerminateProcess(h, 1);
            let _ = CloseHandle(h);
        }
    }
    let _ = fs::remove_file(&path);
}

// ═══════════════════════════════════════
// UI Automation helpers
//
// COM-based UI Automation (IUIAutomation) for finding WT tabs by process ID,
// reading RuntimeIds (stable across tab reorders), and selecting tabs.
// All calls must run on an STA thread (see run_on_sta).
// ═══════════════════════════════════════

fn create_automation() -> windows::core::Result<IUIAutomation> {
    unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }
}

fn find_selected_tab(wt_pid: u32) -> (String, String) {
    unsafe {
        let Ok(auto) = create_automation() else { return Default::default() };
        let Ok(root) = auto.GetRootElement() else { return Default::default() };

        let Ok(pid_cond) = auto.CreatePropertyCondition(
            UIA_ProcessIdPropertyId, &VARIANT::from(wt_pid as i32),
        ) else { return Default::default() };
        let Ok(tab_cond) = auto.CreatePropertyCondition(
            UIA_ControlTypePropertyId, &VARIANT::from(UIA_TabItemControlTypeId.0),
        ) else { return Default::default() };

        let Ok(windows) = root.FindAll(TreeScope_Children, &pid_cond) else { return Default::default() };
        for i in 0..windows.Length().unwrap_or(0) {
            let Ok(win) = windows.GetElement(i) else { continue };
            let Ok(tabs) = win.FindAll(TreeScope_Descendants, &tab_cond) else { continue };

            for j in 0..tabs.Length().unwrap_or(0) {
                let Ok(tab) = tabs.GetElement(j) else { continue };
                if let Ok(pattern) = tab.GetCurrentPattern(UIA_SelectionItemPatternId) {
                    if let Ok(sip) = pattern.cast::<IUIAutomationSelectionItemPattern>() {
                        if sip.CurrentIsSelected().unwrap_or(BOOL::from(false)).as_bool() {
                            let rid = get_runtime_id(&tab);
                            let name = tab.CurrentName().map(|n| n.to_string()).unwrap_or_default();
                            return (rid, name);
                        }
                    }
                }
            }
        }

        Default::default()
    }
}

fn get_runtime_id(element: &IUIAutomationElement) -> String {
    unsafe {
        let Ok(sa) = element.GetRuntimeId() else { return String::new() };
        if sa.is_null() { return String::new(); }

        let lower = SafeArrayGetLBound(sa, 1).unwrap_or(0);
        let upper = SafeArrayGetUBound(sa, 1).unwrap_or(-1);

        let mut ids = Vec::new();
        for i in lower..=upper {
            let mut val: i32 = 0;
            if SafeArrayGetElement(sa, &i, &mut val as *mut _ as *mut std::ffi::c_void).is_ok() {
                ids.push(val.to_string());
            }
        }
        let _ = SafeArrayDestroy(sa);

        ids.join(",")
    }
}

/// Runs a closure on an STA thread (required for UI Automation COM calls).
fn run_on_sta<F, T>(f: F) -> std::result::Result<T, Box<dyn std::any::Any + Send>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    thread::Builder::new()
        .spawn(move || {
            unsafe { let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED); }
            f()
        })
        .expect("failed to spawn STA thread")
        .join()
}

// ═══════════════════════════════════════
// AFK detection
// ═══════════════════════════════════════

fn get_idle_seconds() -> u32 {
    unsafe {
        let mut lii = LASTINPUTINFO {
            cbSize: size_of::<LASTINPUTINFO>() as u32,
            dwTime: 0,
        };
        if GetLastInputInfo(&mut lii).as_bool() {
            let now = GetTickCount();
            (now - lii.dwTime) / 1000
        } else {
            0
        }
    }
}

fn is_session_locked() -> bool {
    // Real lock detection needs WM_WTSSESSION_CHANGE events (message loop).
    // Idle time in is_afk() covers the main use case.
    false
}

fn is_afk(idle_minutes: u32) -> bool {
    if is_session_locked() { return true; }
    get_idle_seconds() >= idle_minutes * 60
}

// ═══════════════════════════════════════
// Webhook
// ═══════════════════════════════════════

/// Sends a webhook by reading a JSON template file and substituting variables.
/// Variables: {{title}}, {{message}}, {{elapsed}}, {{project}}, {{event}}
fn send_webhook(url: &str, template_path: &Path, vars: &[(&str, &str)]) {
    let Ok(mut template) = fs::read_to_string(template_path) else { return };

    for (key, value) in vars {
        template = template.replace(&format!("{{{{{key}}}}}"), value);
    }

    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(10))
        .build();

    let _ = agent.post(url)
        .set("Content-Type", "application/json")
        .send_string(&template);
}

// ═══════════════════════════════════════
// Temp file helpers
// ═══════════════════════════════════════

// Timer file: stores session state as pipe-delimited values in %TEMP%.
// Format: timestamp|wtPid|claudePid|cwd|tabRuntimeId|tabName
fn timer_path(sid: &str) -> PathBuf { env::temp_dir().join(format!("claude-timer-{sid}.txt")) }
fn timer_write(sid: &str, data: &str) { let _ = fs::write(timer_path(sid), data); }
fn timer_read(sid: &str) -> Option<Vec<String>> {
    fs::read_to_string(timer_path(sid)).ok().map(|s| s.splitn(6, '|').map(String::from).collect())
}
fn timer_delete(sid: &str) { let _ = fs::remove_file(timer_path(sid)); }

// Trigger file: empty file in %TEMP%. Created by the protocol handler when the user
// clicks "Focus Terminal". The watcher polls for it every 200ms.
fn trigger_path(sid: &str) -> PathBuf { env::temp_dir().join(format!("claude-focus-trigger-{sid}")) }
fn trigger_delete(sid: &str) { let _ = fs::remove_file(trigger_path(sid)); }

// Watcher PID file: stores the PID of the on-submit watcher process so the next
// on-submit call (or on-end) can kill it.
fn watcher_pid_path(sid: &str) -> PathBuf { env::temp_dir().join(format!("claude-watcher-{sid}.txt")) }
fn watcher_pid_delete(sid: &str) { let _ = fs::remove_file(watcher_pid_path(sid)); }

// ═══════════════════════════════════════
// Misc helpers
// ═══════════════════════════════════════

fn read_stdin() -> Option<serde_json::Value> {
    let mut buf = String::new();
    std::io::stdin().read_to_string(&mut buf).ok()?;
    serde_json::from_str(&buf).ok()
}

/// Escapes special XML characters for toast XML attributes/content.
fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
