import AppKit
import SwiftUI
import StoplightCore

/// The menu bar half of Station: the status item, its panel, and the Settings window.
@MainActor
enum StationMenuBar {
    private static var statusPanel: StatusPanelController?

    static func start() {
        let model = AppModel.shared
        model.start()  // polling + snapshot server, at launch, not on first click
        statusPanel = StatusPanelController(model: model)
        AppIcon.start()
        AgentBoard.shared.start()
        if ProcessInfo.processInfo.environment["STATION_SELFTEST"] == "agents" { AgentsSelfTest.run() }
        Migration.offerIfNeeded()
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
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
