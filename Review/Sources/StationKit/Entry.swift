import AppKit

/// How Station hosts Station: Station runs the launch (CLI, menus, review windows),
/// and Station adds its menu bar through these hooks.
/// What a Station window shows: your agents, your pull requests, or a review (the diff).
public enum StationMode: Int, CaseIterable, Sendable {
    case agents, pullRequests, review
    public var title: String { switch self { case .agents: "Agents"; case .pullRequests: "Pull Requests"; case .review: "Review" } }
}

public enum StationHost {
    /// After Station's menus and windows are up.
    @MainActor public static var didLaunch: (() -> Void)?
    /// Links Station doesn't handle itself (not station://, not a folder).
    @MainActor public static var openURL: ((URL) -> Void)?
    /// Your agents across recent projects: one is working, something waits on you. Set by the host,
    /// which then shows them (Station's menu bar dots) instead of Station's own menu bar icon.
    @MainActor public static var agentsChanged: ((_ working: Bool, _ needsYou: Bool) -> Void)?

    /// The host's view for a mode other than Review (Agents, Pull Requests).
    @MainActor public static var makeModeView: ((StationMode) -> NSViewController)?

    /// The window `show(_:)` switches.
    @MainActor public static var frontWindow: NSWindow? { (NSApp.delegate as? AppDelegate)?.front?.window }

    /// Switch the front window to `mode`. False if there's no window to switch.
    @MainActor @discardableResult public static func show(_ mode: StationMode) -> Bool {
        guard let c = (NSApp.delegate as? AppDelegate)?.front else { return false }
        c.setMode(mode)
        c.window?.present()
        if ProcessInfo.processInfo.environment["STATION_SELFTEST"] == nil { NSApp.activateUnlessTesting() } // tests never take focus
        return true
    }

    /// The review's Settings… menu opens the host's Settings window instead of settings.json.
    @MainActor public static var showSettings: (() -> Void)?

    /// The settings file the review windows read (and watch: hand edits apply live).
    public static var settingsURL: URL { stationConfigDir.appendingPathComponent("settings.json") }
    /// Theme names for the light or dark appearance, built-in first.
    @MainActor public static func themeNames(dark: Bool) -> [String] { Style.shared.themes.filter { $0.isDark == dark }.map(\.name) }
    /// Monospace font families for the review text, the default first.
    @MainActor public static var fontFamilies: [String] { Style.shared.monospaceFamilies }

    /// Open the git repo containing `path` as a review tab (its changes, ready for comments).
    @MainActor public static func openProject(_ path: String) {
        guard let app = NSApp.delegate as? AppDelegate, let root = RecentProjects.repoRoot(of: path) else { return }
        app.openProject(root)
        NSApp.activateUnlessTesting()
    }

    // MARK: Moving from Onramp (Station's migration uses these)

    /// Agents still registered under Onramp's old name. Slow (asks each agent's CLI): call off the main thread.
    public static func onrampAgentRegistrations() -> [String] { AgentIntegration.onrampRegistrations() }
    /// Swap those registrations for Station's. Returns problems, if any. Slow: off the main thread.
    public static func switchAgentsFromOnramp() -> [String] { AgentIntegration.switchFromOnramp() }

    /// `station` in ~/.local/bin, without a dialog. Returns whether it's there now.
    @MainActor @discardableResult public static func installCommand() -> Bool {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return false }
        let link = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/station")
        try? FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: link)
        return (try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: exe)) != nil
    }

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
        PerfMark.mark("main")
        if let status = CLI.run(Array(CommandLine.arguments.dropFirst())) { exit(status) }
        PerfMark.mark("cli")
        let repoPath: String?
        switch CLI.prepareOpen(Array(CommandLine.arguments.dropFirst())) {
        case let .exit(status): exit(status)
        case let .run(repo): repoPath = repo
        }
        PerfMark.mark("prepareOpen")
        MainActor.assumeIsolated { // called from main.swift: the main thread
            let app = NSApplication.shared
            PerfMark.mark("nsapp")
            let delegate = AppDelegate(repoPath: repoPath)
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            PerfMark.mark("run")
            app.run()
        }
        exit(0)
    }
}
