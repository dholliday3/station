import AppKit

/// How Station hosts Onramp: Onramp runs the launch (CLI, menus, review windows),
/// and Station adds its menu bar through these hooks.
public enum OnrampHost {
    /// After Onramp's menus and windows are up.
    @MainActor public static var didLaunch: (() -> Void)?
    /// Links Onramp doesn't handle itself (not onramp://, not a folder).
    @MainActor public static var openURL: ((URL) -> Void)?

    /// `onramp comments|reply|resolve|…` runs the agent CLI and exits; `onramp [repo]` (or a
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
