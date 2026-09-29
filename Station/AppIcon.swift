import AppKit
import Observation

/// The Dock icon (`app_icon` in settings.json: "automatic", "light", "dark"). The app's icon is an
/// Icon Composer icon (AppIcon.icon) with light and dark in it, so on Automatic the system switches
/// it and there's nothing to do. Light or Dark pins the Dock's copy to that look, as macOS renders
/// it, so it keeps macOS's shape (a flat image gets put in a grey plate).
@MainActor
enum AppIcon {
    private static var appearance: NSKeyValueObservation?

    static func start() {
        apply()
        appearance = NSApp.observe(\.effectiveAppearance) { _, _ in MainActor.assumeIsolated { apply() } }
        follow()
    }

    static var choice: String { SettingsFile.shared.value("app_icon") as? String ?? "automatic" }

    private static var pinned: String?

    static func apply() {
        let want = choice == "light" || choice == "dark" ? choice : nil
        guard want != pinned else { return }
        pinned = want
        guard let want else { NSApp.applicationIconImage = nil; return }
        // After the first window draws: not in the middle of launch.
        DispatchQueue.main.async {
            guard pinned == want else { return }
            NSApp.applicationIconImage = rendered(dark: want == "dark")
        }
    }

    /// The app's icon as macOS renders it in light or dark (scripts/make-app-icon.sh makes these
    /// with actool: drawing the icon under a forced appearance at runtime doesn't take).
    static func rendered(dark: Bool) -> NSImage {
        NSImage(named: dark ? "StationIconDark" : "StationIconLight") ?? NSApp.applicationIconImage
    }

    /// Re-apply whenever settings.json changes (the Settings window, or a hand edit).
    private static func follow() {
        withObservationTracking { _ = SettingsFile.shared.values["app_icon"] } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { apply(); follow() } }
        }
    }
}
