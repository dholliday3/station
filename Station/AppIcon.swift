import AppKit
import Observation

/// The Dock icon: follows light and dark mode, or stays Light or Dark (`app_icon` in settings.json:
/// "automatic", "light", "dark"). The app's own icon (Finder) is the dark one; changing the bundle's
/// icon would break its code signature, so only the Dock follows the choice.
@MainActor
enum AppIcon {
    private static var appearance: NSKeyValueObservation?

    static func start() {
        apply()
        appearance = NSApp.observe(\.effectiveAppearance) { _, _ in MainActor.assumeIsolated { apply() } }
        follow()
    }

    static var choice: String { SettingsFile.shared.value("app_icon") as? String ?? "automatic" }

    static func apply() {
        let dark = choice == "dark" || (choice != "light" && NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        if let image = NSImage(named: dark ? "StationIconDark" : "StationIconLight") { NSApp.applicationIconImage = image }
    }

    /// Re-apply whenever settings.json changes (the Settings window, or a hand edit).
    private static func follow() {
        withObservationTracking { _ = SettingsFile.shared.values["app_icon"] } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { apply(); follow() } }
        }
    }
}
