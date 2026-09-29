import AppKit

/// How Station hosts Station: Station runs the launch (CLI, menus, review windows),
/// and Station adds its menu bar through these hooks.
public enum OnrampHost {
    /// After Station's menus and windows are up.
    @MainActor public static var didLaunch: (() -> Void)?
    /// Links Station doesn't handle itself (not station://, not a folder).
    @MainActor public static var openURL: ((URL) -> Void)?
    /// Your agents across recent projects: one is working, something waits on you. Set by the host,
    /// which then shows them (Station's menu bar dots) instead of Station's own menu bar icon.
    @MainActor public static var agentsChanged: ((_ working: Bool, _ needsYou: Bool) -> Void)?

    /// Station's Settings… menu opens the host's Settings window instead of settings.json.
    @MainActor public static var showSettings: (() -> Void)?

    /// The settings file the review windows read (and watch: hand edits apply live).
    public static var settingsURL: URL { onrampConfigDir.appendingPathComponent("settings.json") }
    /// Theme names for the light or dark appearance, built-in first.
    @MainActor public static func themeNames(dark: Bool) -> [String] { Style.shared.themes.filter { $0.isDark == dark }.map(\.name) }
    /// Monospace font families for the review text, the default first.
    @MainActor public static var fontFamilies: [String] { Style.shared.monospaceFamilies }

    /// Open pull request `number` of `repo` ("owner/name") in a review tab, finding the local clone.
    @MainActor public static func openPullRequest(repo: String, number: Int) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        var c = URLComponents()
        c.scheme = "station"
        c.host = "pr"
        c.queryItems = [URLQueryItem(name: "repo", value: repo), URLQueryItem(name: "number", value: String(number))]
        if let url = c.url { DeepLinks.handle(url, app: app) }
    }

    /// Your agents per project, replies waiting on you, Open Recent and Hide Dock Icon: the menu
    /// Station's own menu bar icon had, for the host's menu.
    @MainActor public static func addAgentItems(to menu: NSMenu) { MenuBarItem.shared.addAgentItems(to: menu) }

    /// `station comments|reply|resolve|…` runs the agent CLI and exits; `station [repo]` (or a
    /// plain launch) starts the app. Never returns.
    public static func main() -> Never {
        if let status = CLI.run(Array(CommandLine.arguments.dropFirst())) { exit(status) }
        let repoPath: String?
        switch CLI.prepareOpen(Array(CommandLine.arguments.dropFirst())) {
        case let .exit(status): exit(status)
        case let .run(repo): repoPath = repo
        }
        MainActor.assumeIsolated { // called from main.swift: the main thread
            let app = NSApplication.shared
            let delegate = AppDelegate(repoPath: repoPath)
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            app.run()
        }
        exit(0)
    }
}
