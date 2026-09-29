import AppKit
import SwiftUI
import StoplightCore
import StationKit

/// The menu bar half of Station: the status item, its panel, and the Settings window.
@MainActor
enum StationMenuBar {
    private static var statusPanel: StatusPanelController?

    static func start() {
        let model = AppModel.shared
        PerfMark.mark("station.start")
        model.start()  // polling + snapshot server, at launch, not on first click
        PerfMark.mark("model")
        statusPanel = StatusPanelController(model: model)
        PerfMark.mark("panel")
        AppIcon.start()
        PerfMark.mark("appicon")
        AgentBoard.shared.start()
        PerfMark.mark("agentboard")
        SessionCatalog.shared.start()
        ReviewContextProvider.start()
        PerfMark.mark("catalog")
        StationHost.selectAgent = { AgentsSelection.shared.id = $0 }
        StationHost.currentAgent = { AgentsSelection.shared.id }
        // The main window's Agents and Pull Requests tabs (Review is StationKit's own).
        StationHost.makeModeView = { mode -> NSViewController in
            mode == .agents ? NSHostingController(rootView: AgentsView()) : NSHostingController(rootView: PullRequestsPane(model: model))
        }
        // ⌘⇧A: the Agents window, first in the Review menu.
        if let review = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Review" })?.submenu {
            let item = NSMenuItem(title: "Agents", action: #selector(AgentsWindowOpener.open(_:)), keyEquivalent: "a")
            item.keyEquivalentModifierMask = [.command, .shift]
            item.target = AgentsWindowOpener.shared
            review.insertItem(item, at: 0)
        }
        if ProcessInfo.processInfo.environment["STATION_SELFTEST"] == "perf" { PerfTest.run() }
        if ProcessInfo.processInfo.environment["STATION_SELFTEST"] == "agents" { AgentsSelfTest.run() }
        Migration.offerIfNeeded()
        if ProcessInfo.processInfo.environment["STATION_SELFTEST"] == "agentswindow" {
            AgentsWindow.present()
            for delay in [6.0, 60.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let all = AgentSession.all()
                let counts = AgentSession.Status.allCases.map { s in "\(s.title)=\(all.filter { $0.status == s }.count)" }.joined(separator: " ")
                FileHandle.standardError.write("[selftest] sessions: \(all.count) (\(counts)); with titles \(all.filter { $0.info?.title != nil }.count), with tokens \(all.filter { ($0.info?.totalTokens ?? 0) > 0 }.count), with PRs \(all.filter { $0.info?.pr != nil }.count)\n".data(using: .utf8)!)
                if let out = ProcessInfo.processInfo.environment["STATION_SNAP_OUT"], let w = NSApp.windows.first(where: { $0.title == "Agents" }) {
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-o", "-l", String(w.windowNumber), out]; try? p.run(); p.waitUntilExit()
                }
                if delay > 10 { FileHandle.standardError.write("[selftest] ready\n".data(using: .utf8)!) }
            } }
        }
        if ProcessInfo.processInfo.environment["STATION_SELFTEST"] == "icon", let out = ProcessInfo.processInfo.environment["STATION_SNAP_OUT"] {
            for dark in [false, true] {
                let img = AppIcon.rendered(dark: dark)
                if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(out)-\(dark ? "dark" : "light").png"))
                }
            }
            FileHandle.standardError.write("[selftest] ready\n".data(using: .utf8)!)
        }
        if ProcessInfo.processInfo.environment["STATION_SELFTEST"] == "nav" { // links and the way back
            let repo = ProcessInfo.processInfo.environment["STATION_SELFTEST_REPO"] ?? FileManager.default.currentDirectoryPath
            let steps: [(String, () -> Void)] = [
                ("open project", { StationHost.go(.review(repo: repo)) }),
                ("agents", { StationHost.go(.agents(session: nil)) }),
                ("pull requests", { StationHost.go(.pullRequests) }),
                ("file README.md:5", { StationHost.go(.file(repo: repo, path: "README.md", line: 5)) }),
                ("back", { StationHost.back() }), ("back", { StationHost.back() }), ("back", { StationHost.back() }),
                ("forward", { StationHost.forward() }),
                ("url station://prs", { NSApp.delegate?.application?(NSApp, open: [URL(string: "station://prs")!]) }),
            ]
            for (i, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(i) * 2) {
                    step.1()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        FileHandle.standardError.write("[selftest] \(step.0) → \(StationHost.here.map { "\($0)" } ?? "nowhere")\n".data(using: .utf8)!)
                        if i == steps.count - 1 { FileHandle.standardError.write("[selftest] ready\n".data(using: .utf8)!) }
                    }
                }
            }
        }
        if ProcessInfo.processInfo.environment["STATION_SELFTEST"] == "modes" { // the main window's tabs, one capture each
            let env = ProcessInfo.processInfo.environment
            StationHost.openProject(env["STATION_SELFTEST_REPO"] ?? FileManager.default.currentDirectoryPath)
            for (i, mode) in StationMode.allCases.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4 + Double(i) * 5) {
                    let ok = StationHost.show(mode)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        let w = StationHost.frontWindow
                        FileHandle.standardError.write("[selftest] mode \(mode.title): shown=\(ok) content=\(w.map { "\($0.windowNumber) \(type(of: $0.contentViewController!))" } ?? "none") windows=\(NSApp.windows.filter { $0.toolbar != nil }.map(\.windowNumber))\n".data(using: .utf8)!)
                        if let out = env["STATION_SNAP_OUT"], let w {
                            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                            p.arguments = ["-x", "-o", "-l", String(w.windowNumber), "\(out)-\(mode.rawValue).png"]; try? p.run(); p.waitUntilExit()
                        }
                        if mode == .review { FileHandle.standardError.write("[selftest] ready\n".data(using: .utf8)!) }
                    }
                }
            }
        }
        if ProcessInfo.processInfo.environment["STATION_SELFTEST"] == "migration" { // read-only: what it finds, and the sheet
            let f = Migration.find()
            FileHandle.standardError.write("[selftest] found: stoplight \(f.stoplight.count) keys (\(f.stoplightSummary)); onramp \(f.onramp.count) keys; config \(f.onrampConfig != nil); review data in \(f.reviewData.count) repos; old commands \(f.oldCommands.map(\.lastPathComponent)); apps \(f.apps.map(\.lastPathComponent))\n".data(using: .utf8)!)
            Migration.offer()
        }
    }

    /// station://panel            → show the panel (small widget)
    /// station://panel/<PR node id> → show the panel with that PR selected and expanded
    static func open(_ url: URL) {
        guard url.scheme == "station" else { return }
        let model = AppModel.shared
        let parts = url.pathComponents.dropFirst()
        if url.host == "focus", let id = parts.first { // a notification about one of your agents
            AgentBoard.shared.focus(id: id)
        } else if url.host == "panel", let id = parts.first {
            model.reveal(prID: id)
            model.openPanel?()
        } else if url.host == "agent", parts.count >= 2 {
            // station://agent/<working|attention|done>/<PR id>  (from Claude Code hooks or the agent itself)
            model.agentReported(parts[parts.startIndex], prID: parts[parts.startIndex + 1])
        } else {
            model.openPanel?()
        }
    }
}

/// Settings, in a window of its own (the AppKit launch has no SwiftUI Settings scene).
@MainActor
enum StationSettings {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let model = AppModel.shared
            let root = SettingsView(model: model).environment(\.colorProfile, model.prefs.colorProfile)
            let w = NSWindow(contentViewController: NSHostingController(rootView: root))
            w.title = "Station Settings"
            w.styleMask.insert(.resizable)
            w.setContentSize(NSSize(width: 560, height: 680))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activateUnlessTesting()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A target for menu items that open the Agents window.
@MainActor
final class AgentsWindowOpener: NSObject {
    static let shared = AgentsWindowOpener()
    @objc func open(_ sender: Any?) { AgentsWindow.present() }
}
