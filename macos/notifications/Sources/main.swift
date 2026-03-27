// CC Hooks — macOS notification system
//
// Single binary with subcommands, called by Claude Code hooks (settings.json):
//   on-submit  — UserPromptSubmit hook. Captures session state (timestamp, cwd,
//                terminal, editor, tty) to a temp file for notify to read later.
//   notify     — Notification/Stop hook (async: true). Shows a native notification
//                via UserNotifications framework. Blocks until click/dismiss, then
//                dispatches to focus or editor-open. Replaces by session ID.
//                Falls back to terminal-notifier, then osascript.
//   focus      — Focuses the correct terminal window/tab/pane using AppleScript.
//                Supports Ghostty (by cwd), iTerm2 (by tty), Terminal.app (by tty).
//   on-end     — SessionEnd hook. Cleans up temp files.
//   install    — Merges hook config into ~/.claude/settings.json.
//   uninstall  — Removes hooks from settings.json, cleans up temp files.
//
// Config: ../config.json (relative to binary). See config.json.example.
//   terminal: "ghostty" | "iterm2" | "terminal" (app to focus on click)
//   editor:   "zed" | "code" | "cursor" (app to open project in)
//
// State: /tmp/claude-timer-{session_id}.txt (pipe-delimited session data)
//        /tmp/claude-notifier-{session_id}.txt (PID of notification process)

import Foundation
import CoreGraphics
import UserNotifications
import AppKit

// MARK: - Config

struct Config: Decodable {
    var title: String?
    var terminal: String?
    var editor: String?
    var desktop: Bool?       // false = skip desktop notification (webhook-only mode)
    var sound: String?       // "default", sound name, or "" to disable
    var messages: Messages?
    var icons: Icons?
    var webhook: Webhook?

    struct Messages: Decodable {
        var notification: String?
        var permission: String?
        var elicitation: String?
        var idle: String?
        var stop: String?
    }

    struct Icons: Decodable {
        var app: String?
        var notification: String?
        var permission: String?
        var elicitation: String?
        var idle: String?
        var stop: String?
    }

    struct Webhook: Decodable {
        var enabled: Bool?    // false = disable webhook without removing config
        var url: String?
        var idle_minutes: Int?
        var payload: String?  // Path to JSON template file
    }
}

func loadConfig(baseDir: String) -> Config {
    let path = (baseDir as NSString).appendingPathComponent("config.json")
    guard let data = FileManager.default.contents(atPath: path),
          let config = try? JSONDecoder().decode(Config.self, from: data)
    else { return Config() }
    return config
}

// MARK: - Helpers

func readStdin() -> [String: Any]? {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json
}

func nowMs() -> UInt64 {
    UInt64(Date().timeIntervalSince1970 * 1000)
}

func formatElapsed(_ ms: UInt64) -> String {
    let s = ms / 1000
    if s < 1 { return "(<1s)" }
    if s < 60 { return "(\(s)s)" }
    if s < 3600 { return "(\(s/60)m \(s%60)s)" }
    return "(\(s/3600)h \(s/60%60)m)"
}

/// Escapes a string for safe interpolation into AppleScript
func escapeAppleScript(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
     .replacingOccurrences(of: "\n", with: "\\n")
     .replacingOccurrences(of: "\r", with: "\\r")
     .replacingOccurrences(of: "\t", with: "\\t")
}

/// Escapes a string for safe use inside a single-quoted shell argument.
/// Single quotes can't be escaped inside single quotes, so we end the quote,
/// add an escaped single quote, and re-open the quote: 'foo'\''bar'
func escapeForShellSingleQuote(_ s: String) -> String {
    s.replacingOccurrences(of: "'", with: "'\\''")
}

// MARK: - AFK detection

func getIdleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(
        .combinedSessionState,
        eventType: CGEventType(rawValue: ~0)!  // kCGAnyInputEventType
    )
}

func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        return true // No GUI session (e.g. SSH) — treat as AFK
    }
    return (dict["CGSSessionScreenIsLocked"] as? Int ?? 0) == 1
}

func isAFK(idleMinutes: Int) -> Bool {
    if isScreenLocked() { return true }
    return getIdleSeconds() >= Double(idleMinutes * 60)
}

// MARK: - Webhook

/// Sends a webhook by reading a JSON template file and substituting variables.
/// Variables: {{title}}, {{message}}, {{elapsed}}, {{project}}, {{event}}
func sendWebhook(url: String, templatePath: String, vars: [String: String]) {
    guard let requestUrl = URL(string: url) else { return }
    guard var template = try? String(contentsOfFile: templatePath, encoding: .utf8) else { return }

    for (key, value) in vars {
        template = template.replacingOccurrences(of: "{{\(key)}}", with: value)
    }

    var request = URLRequest(url: requestUrl)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = template.data(using: .utf8)

    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { _, _, _ in
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 10) // 10s timeout
}

/// Maps config terminal name to macOS app name
func terminalAppName(_ terminal: String) -> String {
    switch terminal.lowercased() {
    case "ghostty": return "Ghostty"
    case "iterm", "iterm2": return "iTerm2"
    case "terminal": return "Terminal"
    case "wezterm": return "WezTerm"
    default: return terminal
    }
}

/// Maps config editor name to macOS app name
func editorAppName(_ editor: String) -> String {
    switch editor.lowercased() {
    case "zed": return "Zed"
    case "code", "vscode": return "Visual Studio Code"
    case "cursor": return "Cursor"
    default: return editor
    }
}

/// Runs a shell command and returns stdout
@discardableResult
func shell(_ command: String) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Runs an AppleScript via osascript stdin (avoids shell quoting issues)
@discardableResult
func osascript(_ script: String) -> String {
    let process = Process()
    let outPipe = Pipe()
    let inPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-"]
    process.standardInput = inPipe
    process.standardOutput = outPipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    inPipe.fileHandleForWriting.write(script.data(using: .utf8) ?? Data())
    inPipe.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    return String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Walks the process tree to check if a known terminal emulator is an ancestor.
/// Returns false if running inside an IDE (Zed, VS Code, Cursor, etc.).
func isRunningInTerminal(_ terminal: String) -> Bool {
    let knownTerminals = ["ghostty", "iterm2", "terminal", "wezterm"]
    var pid = ProcessInfo.processInfo.processIdentifier
    for _ in 0..<20 {
        let output = shell("ps -o ppid=,comm= -p \(pid)")
        let trimmed = output.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { break }
        // ppid is first, comm is the rest
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        guard parts.count >= 2 else { break }
        let ppid = Int32(parts[0]) ?? 0
        let comm = String(parts[1])
        let name = (comm as NSString).lastPathComponent.lowercased()
        // Check if this ancestor is the configured terminal or a known one
        if name == terminal.lowercased() || knownTerminals.contains(name) {
            return true
        }
        if ppid <= 1 { break }
        pid = ppid
    }
    return false
}

/// Finds the tty device by walking up the process tree
func findTty() -> String {
    var pid = ProcessInfo.processInfo.processIdentifier
    for _ in 0..<10 {
        let output = shell("ps -o tty=,ppid= -p \(pid)")
        let parts = output.split(separator: " ", maxSplits: 1)
        guard parts.count >= 2 else { break }
        let tty = String(parts[0])
        if tty != "??" && !tty.isEmpty && tty != "-" {
            return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        }
        pid = Int32(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        if pid <= 1 { break }
    }
    return ""
}

// MARK: - Temp files

func timerPath(_ sid: String) -> String { "/tmp/claude-timer-\(sid).txt" }
func notifierPidPath(_ sid: String) -> String { "/tmp/claude-notifier-\(sid).txt" }

func timerWrite(_ sid: String, _ data: String) {
    try? data.write(toFile: timerPath(sid), atomically: true, encoding: .utf8)
}

func timerRead(_ sid: String) -> [String]? {
    guard let content = try? String(contentsOfFile: timerPath(sid), encoding: .utf8)
    else { return nil }
    return content.components(separatedBy: "|")
}

func timerDelete(_ sid: String) {
    try? FileManager.default.removeItem(atPath: timerPath(sid))
}

func notifierPidDelete(_ sid: String) {
    try? FileManager.default.removeItem(atPath: notifierPidPath(sid))
}

/// Kills the previous notification process for this session and waits for it to exit
func killPreviousNotifier(_ sid: String) {
    let path = notifierPidPath(sid)
    guard let content = try? String(contentsOfFile: path, encoding: .utf8),
          let pid = Int32(content.trimmingCharacters(in: .whitespaces)),
          pid > 0
    else { return }
    kill(pid, SIGTERM)
    // Wait briefly for the old process to die so it releases the notification
    for _ in 0..<10 {
        if kill(pid, 0) != 0 { break } // Process is gone
        usleep(50_000) // 50ms
    }
    // Force kill if still alive
    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    try? FileManager.default.removeItem(atPath: path)
}

/// Captures terminal identifiers for pane-level focus restoration.
/// Returns "termId::tabId::windowId" for Ghostty, session ID for iTerm2, pane ID for WezTerm.
func captureTerminalId(_ terminal: String, cwd: String = "", projectRoot: String = "") -> String {
    switch terminal.lowercased() {
    case "ghostty":
        // Match by CWD to avoid race condition when two sessions fire on-submit simultaneously.
        // The focused terminal is only used as a tiebreaker when multiple panes share a directory.
        let eCwd = escapeAppleScript(cwd)
        let eRoot = escapeAppleScript(projectRoot)
        return osascript("""
            tell application "Ghostty"
                set candidates to {}
                set focusedId to ""
                try
                    set focusedId to id of focused terminal of selected tab of front window
                end try
                repeat with w in windows
                    repeat with tb in tabs of w
                        repeat with term in terminals of tb
                            set d to working directory of term
                            if d is "\(eCwd)" or d is "\(eRoot)" or ("\(eCwd)" starts with d and d starts with "\(eRoot)") then
                                set end of candidates to {termId:id of term, tabId:id of tb, winId:id of w}
                            end if
                        end repeat
                    end repeat
                end repeat
                if (count of candidates) is 0 then
                    -- No CWD match; fall back to focused terminal
                    try
                        set w to front window
                        set tb to selected tab of w
                        set ft to focused terminal of tb
                        return (id of ft) & "::" & (id of tb) & "::" & (id of w)
                    end try
                    return ""
                end if
                if (count of candidates) is 1 then
                    set c to item 1 of candidates
                    return (termId of c) & "::" & (tabId of c) & "::" & (winId of c)
                end if
                -- Multiple matches: prefer the focused terminal as tiebreaker
                repeat with c in candidates
                    if (termId of c) is focusedId then
                        return (termId of c) & "::" & (tabId of c) & "::" & (winId of c)
                    end if
                end repeat
                -- None focused; use first candidate
                set c to item 1 of candidates
                return (termId of c) & "::" & (tabId of c) & "::" & (winId of c)
            end tell
            """)
    case "iterm", "iterm2":
        return osascript("""
            tell application "iTerm2" to return id of current session of current tab of current window
            """)
    case "wezterm":
        // $WEZTERM_PANE is set by WezTerm in each pane's environment
        return ProcessInfo.processInfo.environment["WEZTERM_PANE"] ?? ""
    case "terminal":
        // Terminal.app doesn't have split panes — tty is sufficient
        return ""
    default:
        return ""
    }
}

// MARK: - Native notifications (UNUserNotificationCenter)

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onAction: ((String) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        onAction?(response.actionIdentifier)
        handler()
        CFRunLoopStop(CFRunLoopGetMain())
    }

    // Show banner even when our process is considered "foreground"
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound, .badge])
    }
}

/// Posts a native macOS notification with an action button.
/// Click notification body = focus terminal, action button = open editor.
/// Blocks until the user interacts or this process is killed.
/// Returns true if the notification was posted successfully.
func showNativeNotification(title: String, body: String, groupId: String,
                            editorButtonTitle: String, iconPath: String?,
                            soundName: String?,
                            onContentClick: @escaping () -> Void,
                            onEditorClick: @escaping () -> Void) -> Bool {
    // NSApplication is required for UNUserNotificationCenter delegate callbacks.
    // Without it, the notification posts but click handlers never fire.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // No Dock icon, no menu bar

    let center = UNUserNotificationCenter.current()
    let delegate = NotificationDelegate()
    delegate.onAction = { actionId in
        switch actionId {
        case UNNotificationDefaultActionIdentifier:
            onContentClick()
        case "OPEN_EDITOR":
            onEditorClick()
        default:
            break // Dismissed
        }
        // Stop the NSApplication run loop after handling the action
        app.stop(nil)
        // Post a dummy event to ensure the run loop exits immediately
        let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                       modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, subtype: 0, data1: 0, data2: 0)
        if let event = event { app.postEvent(event, atStart: true) }
    }
    center.delegate = delegate

    // Register action category — single button for editor, click body for focus
    let editorAction = UNNotificationAction(
        identifier: "OPEN_EDITOR", title: editorButtonTitle, options: .foreground)
    let category = UNNotificationCategory(
        identifier: "CC_HOOKS", actions: [editorAction],
        intentIdentifiers: [], options: .customDismissAction)
    center.setNotificationCategories([category])

    // Request authorization (shows system prompt on first run)
    var authorized = false
    let authSem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            authorized = granted
            authSem.signal()
        }
    }
    authSem.wait()
    guard authorized else { return false }

    // Replace previous notification for this session
    center.removeDeliveredNotifications(withIdentifiers: [groupId])
    center.removePendingNotificationRequests(withIdentifiers: [groupId])

    // Build notification content
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.categoryIdentifier = "CC_HOOKS"
    content.threadIdentifier = groupId
    if let soundName = soundName {
        if soundName.isEmpty {
            content.sound = nil
        } else if soundName == "default" {
            content.sound = .default
        } else {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName))
        }
    } else {
        content.sound = .default
    }

    // Attach custom icon if available
    // UNNotificationAttachment moves the file, so copy to a temp location first
    if let iconPath = iconPath, FileManager.default.fileExists(atPath: iconPath) {
        let ext = (iconPath as NSString).pathExtension
        let tmpIcon = NSTemporaryDirectory() + "claude-icon-\(UUID().uuidString).\(ext)"
        if (try? FileManager.default.copyItem(atPath: iconPath, toPath: tmpIcon)) != nil,
           let attachment = try? UNNotificationAttachment(
            identifier: "icon", url: URL(fileURLWithPath: tmpIcon)) {
            content.attachments = [attachment]
        }
    }

    // Post notification
    let request = UNNotificationRequest(identifier: groupId, content: content, trigger: nil)
    var postOk = true
    let postSem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        center.add(request) { error in
            if error != nil { postOk = false }
            postSem.signal()
        }
    }
    postSem.wait()
    guard postOk else { return false }

    // Block on NSApplication run loop — callbacks fire here
    app.run()

    return true
}

// MARK: - on-submit

func onSubmit(baseDir: String) -> Int32 {
    guard let json = readStdin(),
          let sid = json["session_id"] as? String
    else { return 1 }

    let config = loadConfig(baseDir: baseDir)
    let terminal = config.terminal ?? "ghostty"

    let inTerminal = isRunningInTerminal(terminal)

    let jsonCwd = json["cwd"] as? String ?? FileManager.default.currentDirectoryPath

    // Extract project root from transcript_path:
    // ~/.claude/projects/-Users-abaldwin-Repos-cc-hooks/session.jsonl
    // The directory name after "projects/" encodes / as - but directory names
    // can also contain dashes, so we greedily resolve against the filesystem.
    let transcriptPath = json["transcript_path"] as? String ?? ""
    let projectRoot: String = {
        let parts = transcriptPath.components(separatedBy: "/projects/")
        guard parts.count > 1 else { return jsonCwd }
        let encoded = parts[1].components(separatedBy: "/").first ?? ""
        guard !encoded.isEmpty, encoded.hasPrefix("-") else { return jsonCwd }

        // Greedily decode: try longest possible path segments first
        let segments = encoded.dropFirst().components(separatedBy: "-")
        var path = "/"
        var i = 0
        while i < segments.count {
            // Try joining successive segments with "-" to handle dashes in names
            var best = ""
            for j in stride(from: segments.count - 1, through: i, by: -1) {
                let candidate = segments[i...j].joined(separator: "-")
                let testPath = (path as NSString).appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: testPath) {
                    best = candidate
                    i = j + 1
                    break
                }
            }
            if best.isEmpty {
                // No match — use single segment
                best = segments[i]
                i += 1
            }
            path = (path as NSString).appendingPathComponent(best)
        }
        return FileManager.default.fileExists(atPath: path) ? path : jsonCwd
    }()

    // CWD relative to project root for display, project root for editor
    let cwd = jsonCwd
    // Skip if running inside an IDE (not a known terminal emulator)
    if !inTerminal { return 0 }
    let ts = nowMs()
    let editor = config.editor ?? "zed"
    let tty = findTty()
    let terminalId = captureTerminalId(terminal, cwd: cwd, projectRoot: projectRoot)

    // Clear any displayed notification for this session — user is actively engaged.
    // Spawn a short-lived background process so we don't block the synchronous hook.
    let selfPath = ProcessInfo.processInfo.arguments[0]
    let clearProc = Process()
    clearProc.executableURL = URL(fileURLWithPath: selfPath)
    clearProc.arguments = ["clear-notification", sid]
    try? clearProc.run()

    // Format: timestamp|cwd|terminal|editor|tty|terminalId|projectRoot
    timerWrite(sid, "\(ts)|\(cwd)|\(terminal)|\(editor)|\(tty)|\(terminalId)|\(projectRoot)")

    return 0
}

// MARK: - notify (async: true — blocks until notification click/dismiss)

func notify(hookEvent: String, baseDir: String) -> Int32 {
    guard let json = readStdin(),
          let sid = json["session_id"] as? String
    else { return 1 }

    let jsonCwd = json["cwd"] as? String
    let notificationType = json["notification_type"] as? String ?? ""

    // Skip auth_success — redundant, user just authenticated
    if notificationType == "auth_success" { return 0 }

    guard let timer = timerRead(sid), timer.count >= 4
    else { return 0 }

    let startMs = UInt64(timer[0]) ?? 0
    let timerCwd = timer[1]
    let terminal = timer[2]
    let editor = timer[3]
    let tty = timer.count > 4 ? timer[4] : ""
    let terminalId = timer.count > 5 ? timer[5] : ""
    let projectRoot = timer.count > 6 ? timer[6] : ""

    // Use jsonCwd for title (shows where Claude is NOW), timer CWD for focus
    let displayCwd = jsonCwd ?? timerCwd
    let focusCwd = timerCwd.isEmpty ? (jsonCwd ?? "") : timerCwd

    // Title: show relative path from project root, e.g. "cc-hooks/macos/notifications"
    let dir: String = {
        if !projectRoot.isEmpty && displayCwd.hasPrefix(projectRoot) {
            let rootName = (projectRoot as NSString).lastPathComponent
            let relative = String(displayCwd.dropFirst(projectRoot.count))
            if relative.isEmpty || relative == "/" {
                return rootName
            }
            let trimmed = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
            return "\(rootName)/\(trimmed)"
        }
        return (displayCwd as NSString).lastPathComponent
    }()
    // Editor always opens at project root
    let editorCwd = projectRoot.isEmpty ? focusCwd : projectRoot

    let config = loadConfig(baseDir: baseDir)
    let elapsed = formatElapsed(nowMs() - startMs)

    let message: String
    if hookEvent == "stop" {
        message = config.messages?.stop ?? "Task completed"
    } else {
        switch notificationType {
        case "permission_prompt":
            message = config.messages?.permission ?? "Claude needs permission"
        case "elicitation_dialog":
            message = config.messages?.elicitation ?? "Action required"
        case "idle_prompt":
            message = config.messages?.idle ?? "Claude is waiting"
        default:
            message = config.messages?.notification ?? "Claude needs your input"
        }
    }

    // Kill previous notification process for this session
    killPreviousNotifier(sid)

    // Icon: per-type from config, falls back to notification icon
    let iconFile: String? = {
        if hookEvent == "stop" { return config.icons?.stop }
        switch notificationType {
        case "permission_prompt": return config.icons?.permission ?? config.icons?.notification
        case "elicitation_dialog": return config.icons?.elicitation ?? config.icons?.notification
        case "idle_prompt": return config.icons?.idle ?? config.icons?.notification
        default: return config.icons?.notification
        }
    }()
    let iconPath = iconFile.map { (baseDir as NSString).appendingPathComponent($0) } ?? ""

    let groupId = "claude-\(sid)"
    let editorButton = "Open in \(editorAppName(editor))"
    let body = "\(message) \(elapsed)"

    // Send webhook after notification (only when AFK, or always if idle_minutes == 0)
    // auth_success is already skipped above
    let elapsedSecs = (nowMs() - startMs) / 1000
    if let webhook = config.webhook, webhook.enabled ?? true,
       let webhookUrl = webhook.url, !webhookUrl.isEmpty,
       let payloadFile = webhook.payload, !payloadFile.isEmpty {
        let idleMinutes = webhook.idle_minutes ?? 15
        let send = idleMinutes == 0
            || (elapsedSecs >= UInt64(idleMinutes) * 60 && isAFK(idleMinutes: idleMinutes))
        if send {
            let templatePath = (baseDir as NSString).appendingPathComponent(payloadFile)
            let vars: [String: String] = [
                "title": config.title ?? dir,
                "message": message,
                "elapsed": elapsed,
                "project": dir,
                "event": hookEvent,
                "notification_type": notificationType,
            ]
            DispatchQueue.global().async {
                sendWebhook(url: webhookUrl, templatePath: templatePath, vars: vars)
            }
        }
    }

    // Skip desktop notification if disabled
    if config.desktop == false {
        notifierPidDelete(sid)
        return 0
    }

    // Save our PID so next notification can kill this process
    try? "\(ProcessInfo.processInfo.processIdentifier)".write(
        toFile: notifierPidPath(sid), atomically: true, encoding: .utf8)

    // Try native macOS notification first
    // Click body = focus terminal, action button = open editor
    let nativeOk = showNativeNotification(
        title: dir, body: body, groupId: groupId,
        editorButtonTitle: editorButton,
        iconPath: FileManager.default.fileExists(atPath: iconPath) ? iconPath : nil,
        soundName: config.sound,
        onContentClick: {
            focusTerminal(terminal: terminal, cwd: focusCwd, tty: tty, terminalId: terminalId)
        },
        onEditorClick: {
            openEditor(editor: editor, cwd: editorCwd)
        }
    )

    if !nativeOk {
        // Fallback: terminal-notifier
        let hasTerminalNotifier = !shell("which terminal-notifier").isEmpty

        if hasTerminalNotifier {
            let senderBundleId: String
            switch terminal.lowercased() {
            case "ghostty": senderBundleId = "com.mitchellh.ghostty"
            case "iterm", "iterm2": senderBundleId = "com.googlecode.iterm2"
            case "terminal": senderBundleId = "com.apple.Terminal"
            default: senderBundleId = "com.mitchellh.ghostty"
            }

            var args = [
                "-title", dir,
                "-message", body,
                "-group", groupId,
                "-sender", senderBundleId,
                "-actions", editorButton,
            ]

            if FileManager.default.fileExists(atPath: iconPath) {
                args += ["-appIcon", iconPath]
            }

            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: shell("which terminal-notifier"))
            process.arguments = args
            process.standardOutput = pipe
            try? process.run()

            // Update PID to terminal-notifier's PID
            try? "\(process.processIdentifier)".write(
                toFile: notifierPidPath(sid), atomically: true, encoding: .utf8)

            process.waitUntilExit()

            let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            switch result {
            case "@CONTENTCLICKED":
                focusTerminal(terminal: terminal, cwd: focusCwd, tty: tty, terminalId: terminalId)
            case let action where action.hasPrefix("Open in"):
                openEditor(editor: editor, cwd: editorCwd)
            default:
                break
            }
        } else {
            // Last resort: osascript (no click actions)
            let eMsg = escapeAppleScript("\(message) \(elapsed)")
            let eDir = escapeAppleScript(dir)
            shell("osascript -e 'display notification \"\(eMsg)\" with title \"\(eDir)\"'")
        }
    }

    notifierPidDelete(sid)
    return 0
}

// MARK: - focus (called directly or after notification click)
//
// Uses terminal-specific AppleScript to find and focus the exact tab/pane.
// Primary match: session ID captured during on-submit.
// Fallback: tty (iTerm2, Terminal.app) or working directory (Ghostty).

func focusTerminal(terminal: String, cwd: String, tty: String, terminalId: String) {
    let eCwd = escapeAppleScript(cwd)
    let eTty = escapeAppleScript(tty)
    let eTermId = escapeAppleScript(terminalId)

    switch terminal.lowercased() {
    case "ghostty":
        // terminalId format: "termId::tabId::windowId" (captured at on-submit)
        let parts = terminalId.components(separatedBy: "::")
        let termId = parts.count > 0 ? escapeAppleScript(parts[0]) : ""
        let tabId = parts.count > 1 ? escapeAppleScript(parts[1]) : ""
        let windowId = parts.count > 2 ? escapeAppleScript(parts[2]) : ""
        // activate window deminiaturizes + brings to front (calls makeKeyAndOrderFront)
        // System Events cannot see Ghostty windows (GPU/Metal rendering)
        // Ghostty tabs don't support select/set via AppleScript, but
        // "focus terminal" auto-switches to the terminal's tab.
        osascript("""
            tell application "Ghostty"
                -- Primary: activate window + focus terminal by ID
                if "\(termId)" is not "" and "\(windowId)" is not "" then
                    try
                        set w to window id "\(windowId)"
                        activate window w
                        if "\(tabId)" is not "" then
                            repeat with t in terminals of (tab id "\(tabId)" of w)
                                if (id of t) is "\(termId)" then
                                    focus t
                                    return
                                end if
                            end repeat
                        end if
                    end try
                end if
                -- Fallback: search all terminals by CWD
                activate
                if "\(eCwd)" is not "" then
                    try
                        repeat with w in windows
                            repeat with tb in tabs of w
                                repeat with term in terminals of tb
                                    set d to working directory of term
                                    if d is "\(eCwd)" or "\(eCwd)" starts with (d & "/") or d starts with ("\(eCwd)" & "/") then
                                        activate window w
                                        focus term
                                        return
                                    end if
                                end repeat
                            end repeat
                        end repeat
                    end try
                end if
            end tell
            """)
    case "iterm", "iterm2":
        osascript("""
            tell application "iTerm2" to activate
            tell application "iTerm2"
                -- Pass 1: session ID match
                if "\(eTermId)" is not "" then
                    repeat with w in windows
                        repeat with tb in tabs of w
                            repeat with sess in sessions of tb
                                if id of sess is "\(eTermId)" then
                                    set index of w to 1
                                    select tb
                                    select sess
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end if
                -- Pass 2: CWD + "Claude" in name
                repeat with w in windows
                    repeat with tb in tabs of w
                        repeat with sess in sessions of tb
                            set sessDir to variable named "path" in sess
                            if name of sess contains "Claude" and sessDir is "\(eCwd)" then
                                set index of w to 1
                                select tb
                                select sess
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
                -- Pass 3: prefix CWD match
                repeat with w in windows
                    repeat with tb in tabs of w
                        repeat with sess in sessions of tb
                            set sessDir to variable named "path" in sess
                            if ("\(eCwd)" starts with sessDir or sessDir starts with "\(eCwd)") then
                                set index of w to 1
                                select tb
                                select sess
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """)

    case "terminal":
        osascript("""
            tell application "Terminal" to activate
            tell application "Terminal"
                -- Pass 1: tty match
                if "\(eTty)" is not "" then
                    repeat with w in windows
                        repeat with tb in tabs of w
                            if tty of tb is "\(eTty)" then
                                set selected tab of w to tb
                                set index of w to 1
                                return
                            end if
                        end repeat
                    end repeat
                end if
                -- Pass 2: Claude process match
                repeat with w in windows
                    repeat with tb in tabs of w
                        if custom title of tb contains "Claude" or processes of tb contains "claude" then
                            set selected tab of w to tb
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """)

    case "wezterm":
        if !terminalId.isEmpty {
            let sTermId = escapeForShellSingleQuote(terminalId)
            shell("wezterm cli activate-pane --pane-id '\(sTermId)'")
        }
        osascript("tell application \"WezTerm\" to activate")

    default:
        let appName = terminalAppName(terminal)
        osascript("tell application \"\(appName)\" to activate")
    }
}

func openEditor(editor: String, cwd: String) {
    let appName = editorAppName(editor)
    let sCwd = escapeForShellSingleQuote(cwd)
    let sApp = escapeForShellSingleQuote(appName)
    let eApp = escapeAppleScript(appName)
    // Use the project directory basename to find the matching window title.
    // Editors typically show the project folder name in the window title.
    // AXRaise + set frontmost brings only that window to front, even from Stage Manager.
    // Returns "raised" if successful so we can skip the open command.
    let dirName = escapeAppleScript((cwd as NSString).lastPathComponent)
    let raised = osascript("""
        tell application "System Events"
            set appProc to first process whose name is "\(eApp)"
            repeat with w in windows of appProc
                if name of w contains "\(dirName)" then
                    perform action "AXRaise" of w
                    return "raised"
                end if
            end repeat
        end tell
        """)
    if raised == "raised" { return }
    switch editor.lowercased() {
    case "zed":
        shell("open -a '\(sApp)' '\(sCwd)'")
    case "code", "vscode":
        shell("code '\(sCwd)'")
    case "cursor":
        shell("cursor '\(sCwd)'")
    default:
        shell("open -a '\(sApp)' '\(sCwd)'")
    }
}

// MARK: - on-end

func onEnd() -> Int32 {
    guard let json = readStdin(),
          let sid = json["session_id"] as? String
    else { return 1 }

    killPreviousNotifier(sid)
    timerDelete(sid)
    notifierPidDelete(sid)
    return 0
}

// MARK: - Install / Uninstall

func settingsPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return (home as NSString).appendingPathComponent(".claude/settings.json")
}

func installHooks(exePath: String) -> Int32 {
    let path = settingsPath()
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    var settings: [String: Any] = [:]
    if let data = FileManager.default.contents(atPath: path),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        settings = json
    }

    // Notification and Stop hooks are async because the notification handler
    // blocks until the user clicks/dismisses.
    let quotedExe = "'\(escapeForShellSingleQuote(exePath))'"
    let hookEntries: [(String, String, Bool)] = [
        ("UserPromptSubmit", "\(quotedExe) on-submit", false),
        ("Notification", "\(quotedExe) notify notification", true),
        ("Stop", "\(quotedExe) notify stop", true),
        ("SessionEnd", "\(quotedExe) on-end", false),
    ]

    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    for (event, command, isAsync) in hookEntries {
        var hookDef: [String: Any] = ["type": "command", "command": command]
        if isAsync { hookDef["async"] = true }
        hooks[event] = [["matcher": "", "hooks": [hookDef]]]
    }
    settings["hooks"] = hooks

    guard let data = try? JSONSerialization.data(
        withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
          let json = String(data: data, encoding: .utf8)
    else { return 1 }

    try? json.write(toFile: path, atomically: true, encoding: .utf8)
    print("Updated \(path)")

    print("Note: Notifications use native macOS APIs. On first run, you may need")
    print("to grant notification permissions when prompted.")
    print("Optional: `brew install terminal-notifier` as a fallback.")

    return 0
}

func uninstallHooks() -> Int32 {
    // Clean temp files
    let fm = FileManager.default
    if let files = try? fm.contentsOfDirectory(atPath: "/tmp") {
        for file in files where file.hasPrefix("claude-timer-") || file.hasPrefix("claude-notifier-") {
            try? fm.removeItem(atPath: "/tmp/\(file)")
        }
    }

    // Remove hooks from settings.json
    let path = settingsPath()
    guard let data = fm.contents(atPath: path),
          var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var hooks = settings["hooks"] as? [String: Any]
    else {
        print("Uninstalled")
        return 0
    }

    for event in ["UserPromptSubmit", "Notification", "Stop", "SessionEnd"] {
        guard let entries = hooks[event] as? [[String: Any]] else { continue }
        let filtered = entries.filter { entry in
            guard let hookList = entry["hooks"] as? [[String: Any]] else { return true }
            return !hookList.contains { ($0["command"] as? String ?? "").contains("notifications") }
        }
        if filtered.isEmpty { hooks.removeValue(forKey: event) }
        else { hooks[event] = filtered }
    }

    if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
    else { settings["hooks"] = hooks }

    if let data = try? JSONSerialization.data(
        withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    print("Uninstalled")
    return 0
}

// MARK: - Entry point

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: notifications <on-submit|notify|focus|on-end|install|uninstall>\n", stderr)
    exit(1)
}

// baseDir = the notifications/ directory (where config.json and icons/ live)
// Walk up from the binary looking for config.json.
// Works from bin/, .build/, or any nested location.
let exePath = (args[0] as NSString).resolvingSymlinksInPath
let baseDir: String = {
    var dir = (exePath as NSString).deletingLastPathComponent
    while !dir.isEmpty && dir != "/" {
        if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("config.json")) {
            return dir
        }
        dir = (dir as NSString).deletingLastPathComponent
    }
    return (exePath as NSString).deletingLastPathComponent
}()

let code: Int32
switch args[1] {
case "on-submit":
    code = onSubmit(baseDir: baseDir)
case "notify":
    let event = args.count > 2 ? args[2] : "notification"
    code = notify(hookEvent: event, baseDir: baseDir)
case "focus":
    // Direct focus by session ID
    if let timer = timerRead(args.count > 2 ? args[2] : ""),
       timer.count >= 4 {
        focusTerminal(
            terminal: timer[2], cwd: timer[1],
            tty: timer.count > 4 ? timer[4] : "",
            terminalId: timer.count > 5 ? timer[5] : "")
    }
    code = 0
case "on-end":
    code = onEnd()
case "clear-notification":
    // Spawned by on-submit to clear displayed notifications without blocking.
    // Needs NSApplication for UNUserNotificationCenter to work.
    let sid = args.count > 2 ? args[2] : ""
    if !sid.isEmpty {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let center = UNUserNotificationCenter.current()
        let groupId = "claude-\(sid)"
        center.removeDeliveredNotifications(withIdentifiers: [groupId])
        center.removePendingNotificationRequests(withIdentifiers: [groupId])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }
    code = 0
case "install":
    code = installHooks(exePath: exePath)
case "uninstall":
    code = uninstallHooks()
default:
    fputs("Unknown: \(args[1])\n", stderr)
    code = 1
}

exit(code)
