import AppKit
import Observation
import UserNotifications
import onramp

/// Every Claude Code session on this Mac, from the files `station hook` keeps in
/// ~/.config/station/agents/: which need you, which are working, which are done.
@MainActor
@Observable
final class AgentBoard {
    static let shared = AgentBoard()

    enum State: String { case needsYou = "needs_you", working, done, ready
        var rank: Int { switch self { case .needsYou: 0; case .working: 1; case .done: 2; case .ready: 3 } }
    }

    struct Agent: Identifiable, Equatable {
        let id: String
        let agent: String
        let cwd: String
        let pid: Int32?
        let state: State
        let task: String?
        let detail: String?
        let since: Date
        var project: String { (cwd as NSString).lastPathComponent }
    }

    private(set) var agents: [Agent] = []
    /// Branch per folder, looked up once in the background.
    private(set) var branches: [String: String] = [:]
    var needsYou: Int { agents.filter { $0.state == .needsYou }.count }
    /// Claude Code's hooks point at `station hook` (you turned it on).
    private(set) var installed = false

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loadedOnce = false

    func start() {
        installed = ClaudeHooks.isInstalled()
        if installed { ClaudeHooks.install() } // Station moved or updated: keep the hooks pointing at this copy
        try? FileManager.default.createDirectory(at: AgentHook.dir, withIntermediateDirectories: true)
        let fd = open(AgentHook.dir.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { AgentBoard.shared.load() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            watcher = source
        }
        // Sessions whose Claude quit without saying so, and the "4m" beside each row.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in MainActor.assumeIsolated { AgentBoard.shared.load() } }
        load()
    }

    func turnOn() {
        ClaudeHooks.install()
        installed = ClaudeHooks.isInstalled()
    }

    func turnOff() {
        ClaudeHooks.uninstall()
        installed = false
    }

    // MARK: Loading

    func load() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: AgentHook.dir, includingPropertiesForKeys: nil)) ?? []
        var list: [Agent] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = r["session"] as? String, let cwd = r["cwd"] as? String else { continue }
            let pid = (r["pid"] as? NSNumber).map { Int32($0.intValue) }
            let updated = Date(timeIntervalSince1970: (r["updated"] as? NSNumber)?.doubleValue ?? 0)
            // Gone: its Claude process exited (closed terminal, crash), or nothing heard for a day.
            if let pid, kill(pid, 0) != 0, errno == ESRCH { try? fm.removeItem(at: url); continue }
            if Date().timeIntervalSince(updated) > 24 * 3600 { try? fm.removeItem(at: url); continue }
            list.append(Agent(id: id, agent: r["agent"] as? String ?? "claude", cwd: cwd, pid: pid,
                              state: State(rawValue: r["state"] as? String ?? "") ?? .ready,
                              task: r["task"] as? String, detail: r["detail"] as? String,
                              since: Date(timeIntervalSince1970: (r["since"] as? NSNumber)?.doubleValue ?? updated.timeIntervalSince1970)))
        }
        list.sort { ($0.state.rank, $1.since) < ($1.state.rank, $0.since) }
        let before = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        if list != agents { agents = list }
        if loadedOnce {
            for a in list where before[a.id]?.state != a.state && (a.state == .needsYou || (a.state == .done && before[a.id] != nil)) { notify(a) }
        }
        loadedOnce = true
        for a in list where branches[a.cwd] == nil { lookUpBranch(a.cwd) }
    }

    private func lookUpBranch(_ cwd: String) {
        branches[cwd] = ""
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            p.waitUntilExit()
            let branch = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { MainActor.assumeIsolated { AgentBoard.shared.branches[cwd] = p.terminationStatus == 0 ? branch : "" } }
        }
    }

    // MARK: Telling you

    private func notify(_ a: Agent) {
        let content = UNMutableNotificationContent()
        content.title = a.state == .needsYou ? "\(a.agent) needs you · \(a.project)" : "\(a.agent) is done · \(a.project)"
        content.body = (a.state == .needsYou ? a.detail : a.task) ?? ""
        content.userInfo = ["url": "station://focus/\(a.id)"]
        content.threadIdentifier = "agent-\(a.id)"
        content.sound = a.state == .needsYou ? .default : nil
        content.interruptionLevel = a.state == .needsYou ? .timeSensitive : .active
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "agent-\(a.id)-\(a.state.rawValue)", content: content, trigger: nil))
    }

    // MARK: Going to it

    func focus(id: String) {
        if let a = agents.first(where: { $0.id == id }) { focus(a) }
    }

    /// Bring the agent's terminal to the front: its tab in Terminal or iTerm, else whichever app
    /// runs it (VS Code, Cursor, Ghostty…).
    func focus(_ a: Agent) {
        guard let pid = a.pid else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var p = pid, hosts: [pid_t] = []
            for _ in 0..<16 {
                p = Self.parent(of: p)
                guard p > 1 else { break }
                hosts.append(p)
            }
            let tty = Self.ps("tty=", pid).map { "/dev/" + $0 }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let app = hosts.lazy.compactMap { NSRunningApplication(processIdentifier: $0) }.first { $0.activationPolicy == .regular }
                    if let tty, let id = app?.bundleIdentifier, let script = Self.selectTab(app: id, tty: tty) {
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                        p.arguments = ["-e", script]
                        p.standardOutput = FileHandle.nullDevice
                        p.standardError = FileHandle.nullDevice
                        try? p.run()
                    }
                    app?.activate()
                }
            }
        }
    }

    /// Open the agent's folder as a review: what it changed, ready for comments.
    func review(_ a: Agent) { OnrampHost.openProject(a.cwd) }

    nonisolated private static func selectTab(app: String, tty: String) -> String? {
        switch app {
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected tab of w to t
                    set index of w to 1
                  end if
                end repeat
              end repeat
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      select t
                      select s
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            """
        default:
            return nil
        }
    }

    nonisolated private static func parent(of pid: pid_t) -> pid_t {
        ps("ppid=", pid).flatMap { pid_t($0) } ?? 0
    }

    nonisolated private static func ps(_ field: String, _ pid: pid_t) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", field, "-p", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || s == "??" ? nil : s
    }
}

/// Station's entries in ~/.claude/settings.json: one hook per lifecycle event, each running
/// `station hook`. Everything else in that file (your own hooks too) is left as it is.
enum ClaudeHooks {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"]
    /// STATION_CLAUDE_SETTINGS: a copy to work on (self-tests never touch your real one).
    static var settingsURL: URL {
        ProcessInfo.processInfo.environment["STATION_CLAUDE_SETTINGS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    /// `$PPID` is the Claude process: the board drops the session when it exits.
    static var command: String { "'\(Bundle.main.executablePath ?? "/Applications/Station.app/Contents/MacOS/Station")' hook --pid $PPID" }

    private static func isOurs(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains("' hook --pid") == true && ($0["command"] as? String)?.contains("Station") == true }
    }

    private static func read() -> [String: Any] {
        (try? Data(contentsOf: settingsURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private static func write(_ settings: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: settingsURL, options: .atomic)
    }

    static func isInstalled() -> Bool {
        let hooks = read()["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { (hooks[$0] as? [Any] ?? []).contains(where: isOurs) }
    }

    /// Add (or refresh) Station's hook on each event, keeping every other entry.
    static func install() {
        var settings = read()
        guard (try? Data(contentsOf: settingsURL)) == nil || !settings.isEmpty else { return } // unreadable JSON: leave it alone
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = (hooks[event] as? [Any] ?? []).filter { !isOurs($0) }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if event == "PreToolUse" || event == "PermissionRequest" { entry["matcher"] = "*" }
            entries.append(entry)
            hooks[event] = entries
        }
        settings["hooks"] = hooks
        write(settings)
    }

    static func uninstall() {
        var settings = read()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for event in events {
            let kept = (hooks[event] as? [Any] ?? []).filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        write(settings)
    }
}
