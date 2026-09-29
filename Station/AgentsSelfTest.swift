import AppKit
import StationKit

/// STATION_SELFTEST=agents (with STATION_CONFIG_DIR and STATION_CLAUDE_SETTINGS on scratch copies):
/// hooks in and out of Claude Code's settings, fake sessions on the board, a picture of the panel.
@MainActor
enum AgentsSelfTest {
    static func log(_ s: String) { FileHandle.standardError.write("[selftest] \(s)\n".data(using: .utf8)!) }

    static func run() {
        Task { @MainActor in
            let board = AgentBoard.shared
            let before = try? Data(contentsOf: ClaudeHooks.settingsURL)
            let beforeKeys = before.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }.map { Set($0.keys) } ?? []
            log("installed before: \(board.installed)")
            board.turnOn()
            let after = (try? Data(contentsOf: ClaudeHooks.settingsURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let hooks = after["hooks"] as? [String: Any] ?? [:]
            log("installed after: \(board.installed); keys kept: \(beforeKeys.isSubset(of: Set(after.keys))); hooks per event: " +
                ClaudeHooks.events.map { "\($0)=\((hooks[$0] as? [Any])?.count ?? 0)" }.joined(separator: " "))
            board.turnOn() // again: still one of ours per event
            let again = ((try? Data(contentsOf: ClaudeHooks.settingsURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["hooks"] as? [String: Any]) ?? [:]
            log("after a second turn-on: " + ClaudeHooks.events.map { "\($0)=\((again[$0] as? [Any])?.count ?? 0)" }.joined(separator: " "))

            // Sessions: three live (this process stands in for Claude), one whose Claude is gone.
            let me = Int(getpid()), now = Date().timeIntervalSince1970
            let fake: [[String: Any]] = [
                ["session": "a1", "cwd": FileManager.default.currentDirectoryPath, "pid": me, "state": "needs_you", "detail": "Claude needs your permission to use Bash", "task": "Fix the flaky booking test", "since": now - 240],
                ["session": "a2", "cwd": "/tmp/station-demo", "pid": me, "state": "working", "detail": "Edit SharedStore.swift", "task": "Move the widget to its own port", "since": now - 720],
                ["session": "a3", "cwd": "/tmp/station-site", "pid": me, "state": "done", "task": "Tighten the landing page copy", "since": now - 60],
                ["session": "a4", "cwd": "/tmp/gone", "pid": 999_999, "state": "working", "since": now],
            ]
            try? FileManager.default.createDirectory(at: AgentHook.dir, withIntermediateDirectories: true)
            for var f in fake {
                f["agent"] = "claude"; f["updated"] = now; f["started"] = now - 900
                let data = try! JSONSerialization.data(withJSONObject: f)
                try? data.write(to: AgentHook.dir.appendingPathComponent("\(f["session"]!).json"))
            }
            board.load()
            log("board: \(board.agents.map { "\($0.project)=\($0.state.rawValue)" }.joined(separator: ", ")); needs you: \(board.needsYou); dots say: \(AppModel.shared.agentsNeedingYou)")
            log("gone session's file removed: \(!FileManager.default.fileExists(atPath: AgentHook.dir.appendingPathComponent("a4.json").path))")

            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 500_000_000)
            AppModel.shared.openPanel?()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            log("windows: " + NSApp.windows.map { "\(type(of: $0))(\($0.isVisible ? "shown" : "hidden"))" }.joined(separator: ", "))
            if let out = ProcessInfo.processInfo.environment["STATION_SNAP_OUT"],
               let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", String(panel.windowNumber), out]
                try? p.run(); p.waitUntilExit()
                log("panel snapped")
            }
            board.turnOff()
            let restored = (try? Data(contentsOf: ClaudeHooks.settingsURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let beforeObj = before.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            log("after turn-off: installed \(board.installed); settings back as they were: \(NSDictionary(dictionary: restored).isEqual(to: beforeObj))")
            log("ready")
        }
    }
}
