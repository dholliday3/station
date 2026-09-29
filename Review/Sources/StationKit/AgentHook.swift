import Foundation

/// `station hook [--pid <pid>]`: Claude Code runs this on its lifecycle events (Station installs
/// the hooks in ~/.claude/settings.json when you turn it on). Each run updates that session's
/// file in ~/.config/station/agents/, which the app watches. It prints nothing (a prompt hook's
/// output would reach the model), always exits 0 (never blocks the agent), and takes milliseconds.
public enum AgentHook {
    /// One file per session: `<session id>.json`.
    public static var dir: URL { stationConfigDir.appendingPathComponent("agents") }

    static func run(_ args: [String]) -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let e = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let id = e["session_id"] as? String, !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return 0 }
        let url = dir.appendingPathComponent(id + ".json")
        let event = e["hook_event_name"] as? String ?? ""
        if event == "SessionEnd" {
            try? FileManager.default.removeItem(at: url)
            return 0
        }
        var r = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let now = Date().timeIntervalSince1970
        if r["started"] == nil { r["started"] = now; r["since"] = now }
        r["session"] = id
        r["agent"] = "claude"
        r["updated"] = now
        if let cwd = e["cwd"] as? String { r["cwd"] = cwd }
        if let t = e["transcript_path"] as? String { r["transcript"] = t }
        if let i = args.firstIndex(of: "--pid"), i + 1 < args.count, let pid = Int(args[i + 1]), pid > 1 { r["pid"] = pid }
        let state = r["state"] as? String
        func set(_ s: String, detail: String?) {
            if state != s { r["since"] = now }
            r["state"] = s
            r["detail"] = detail
        }
        switch event {
        case "SessionStart":
            if state == nil { set("ready", detail: nil) }
        case "UserPromptSubmit":
            set("working", detail: nil)
            r["task"] = oneLine(e["prompt"] as? String, 120)
        case "PreToolUse":
            set("working", detail: tool(e))
        case "PermissionRequest":
            set("needs_you", detail: "Permission: " + (tool(e) ?? "a tool"))
        case "Notification":
            // "Claude needs your permission to use Bash": waiting on you. The idle reminder after a
            // finished turn changes nothing: the session is already done.
            let message = e["message"] as? String ?? ""
            if message.localizedCaseInsensitiveContains("permission") || state == "working" { set("needs_you", detail: oneLine(message, 120)) }
        case "Stop":
            set("done", detail: nil)
            // What it said last: the notification tells you the answer, not your own prompt back.
            r["summary"] = (r["transcript"] as? String).flatMap(lastReply).flatMap { oneLine($0, 160) }
        default:
            return 0
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) { try? data.write(to: url, options: .atomic) }
        return 0
    }

    /// The text of the transcript's last assistant message. Reads only the file's tail.
    static func lastReply(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"assistant\""), let e = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  e["type"] as? String == "assistant", let m = e["message"] as? [String: Any], let content = m["content"] as? [[String: Any]] else { continue }
            let words = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: " ")
            if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return words }
        }
        return nil
    }

    /// "Edit SharedStore.swift", "Bash: pnpm test", "Grep: TODO".
    static func tool(_ e: [String: Any]) -> String? {
        guard let name = e["tool_name"] as? String else { return nil }
        let input = e["tool_input"] as? [String: Any] ?? [:]
        if let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String {
            return "\(name) \((path as NSString).lastPathComponent)"
        }
        if let what = (input["command"] ?? input["pattern"] ?? input["url"] ?? input["description"] ?? input["query"]) as? String {
            return "\(name): \(oneLine(what, 80) ?? "")"
        }
        return name
    }

    static func oneLine(_ s: String?, _ max: Int) -> String? {
        guard let s else { return nil }
        let line = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }
}
