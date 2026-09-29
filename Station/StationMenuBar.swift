import AppKit
import SwiftUI
import StoplightCore

/// Stoplight's half of Station: the status item, its panel, and the Settings window.
@MainActor
enum StationMenuBar {
    private static var statusPanel: StatusPanelController?

    static func start() {
        let model = AppModel.shared
        model.start()  // polling + snapshot server, at launch, not on first click
        statusPanel = StatusPanelController(model: model)
    }

    /// stoplight://open            → show the panel (small widget)
    /// stoplight://pr/<PR node id> → show the panel with that PR selected and expanded
    static func open(_ url: URL) {
        guard url.scheme == "stoplight" else { return }
        let model = AppModel.shared
        let parts = url.pathComponents.dropFirst()
        if url.host == "pr", let id = parts.first {
            model.reveal(prID: id)
            model.openPanel?()
        } else if url.host == "agent", parts.count >= 2 {
            // stoplight://agent/<working|attention|done>/<PR id>  (from Claude Code hooks or the agent itself)
            model.agentReported(parts[parts.startIndex], prID: parts[parts.startIndex + 1])
        } else {
            model.openPanel?()
        }
    }
}

/// Stoplight's Settings, in a window of its own (Onramp's AppKit launch has no SwiftUI Settings scene).
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
