import AppKit

/// Everywhere you can be in Station. Every link in the app — a click, ⌘K, a notification, a
/// station:// URL — is one of these, handed to `Navigator.go`.
public enum Destination: Hashable, Sendable {
    /// The Agents tab, with a session selected.
    case agents(session: String?)
    /// The Pull Requests tab.
    case pullRequests
    /// A project's review, showing whatever it shows (the branch, uncommitted work…).
    case review(repo: String)
    /// A pull request's diff. `repo`: a clone's path, or "owner/name" (Station finds the clone).
    case pullRequest(repo: String, number: Int)
    /// One commit's diff.
    case commit(repo: String, sha: String)
    /// A file in a project's review, at a line (1-based).
    case file(repo: String, path: String, line: Int?)
    /// A comment thread, scrolled into view.
    case comment(repo: String, thread: String)
    /// Somewhere outside Station (GitHub, a CI log).
    case web(URL)

    /// station://agents/<id>, station://prs, station://review?repo=…, station://pr?repo=…&number=…,
    /// station://commit?repo=…&sha=…, station://file?repo=…&path=…&line=…, station://comment?repo=…&id=…
    public var url: URL {
        var c = URLComponents()
        c.scheme = "station"
        func q(_ items: [String: String?]) { c.queryItems = items.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name } }
        switch self {
        case let .agents(id): c.host = "agents"; if let id { c.path = "/" + id }
        case .pullRequests: c.host = "prs"
        case let .review(repo): c.host = "review"; q(["repo": repo])
        case let .pullRequest(repo, n): c.host = "pr"; q(["repo": repo, "number": String(n)])
        case let .commit(repo, sha): c.host = "commit"; q(["repo": repo, "sha": sha])
        case let .file(repo, path, line): c.host = "file"; q(["repo": repo, "path": path, "line": line.map(String.init)])
        case let .comment(repo, id): c.host = "comment"; q(["repo": repo, "id": id])
        case let .web(u): return u
        }
        return c.url!
    }

    /// A station:// link Station itself handles (the menu bar's own panel/agent/focus links aren't).
    public init?(url: URL) {
        guard url.scheme == "station" else { return nil }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ name: String) -> String? { q.first { $0.name == name }?.value }
        let tail = url.path.split(separator: "/").first.map(String.init)
        switch url.host {
        case "agents": self = .agents(session: tail)
        case "prs": self = .pullRequests
        case "review": guard let r = v("repo") else { return nil }; self = .review(repo: r)
        case "open": guard let r = v("path") else { return nil }; self = .review(repo: r)
        case "pr": guard let r = v("repo"), let n = v("number").flatMap(Int.init) else { return nil }; self = .pullRequest(repo: r, number: n)
        case "commit": guard let r = v("repo"), let s = v("sha") else { return nil }; self = .commit(repo: r, sha: s)
        case "file": guard let r = v("repo"), let p = v("path") else { return nil }; self = .file(repo: r, path: p, line: v("line").flatMap(Int.init))
        case "comment": guard let r = v("repo"), let id = v("id") else { return nil }; self = .comment(repo: r, thread: id)
        default: return nil
        }
    }
}

/// Where you are, whether you can go back or forward: the toolbar's arrows follow this.
@MainActor
@Observable
public final class NavigationState {
    public static let shared = NavigationState()
    public fileprivate(set) var canGoBack = false
    public fileprivate(set) var canGoForward = false
}

/// Goes anywhere in Station and remembers the way back, like a browser: ⌘[ and ⌘] (and the
/// toolbar's arrows) walk the trail across tabs, projects, agents and PRs.
@MainActor
public enum Navigator {
    private static var backStack: [Destination] = []
    private static var forwardStack: [Destination] = []

    public static func go(_ destination: Destination) {
        if case .web = destination { return open(destination) } // leaves Station: nothing to come back to
        if let here = here(), here != destination {
            backStack.append(here)
            if backStack.count > 100 { backStack.removeFirst() }
            forwardStack.removeAll()
        }
        open(destination)
        publish()
    }

    public static func back() {
        guard let d = backStack.popLast() else { return NSSound.beep() }
        if let here = here() { forwardStack.append(here) }
        open(d)
        publish()
    }

    public static func forward() {
        guard let d = forwardStack.popLast() else { return NSSound.beep() }
        if let here = here() { backStack.append(here) }
        open(d)
        publish()
    }

    /// Where the front window is now.
    static func here() -> Destination? { (NSApp.delegate as? AppDelegate)?.front?.location }

    private static func publish() {
        NavigationState.shared.canGoBack = !backStack.isEmpty
        NavigationState.shared.canGoForward = !forwardStack.isEmpty
    }

    private static func open(_ d: Destination) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        switch d {
        case let .agents(id):
            guard let c = app.windowForNavigation() else { return }
            c.setMode(.agents)
            if let id { StationHost.selectAgent?(id) }
            c.window?.present()
        case .pullRequests:
            guard let c = app.windowForNavigation() else { return }
            c.setMode(.pullRequests)
            c.window?.present()
        case let .review(repo):
            guard let root = RecentProjects.repoRoot(of: repo) else { return DeepLinks.alert("Couldn't open \((repo as NSString).lastPathComponent)", "\(repo) isn't a git repository (any more).") }
            app.openProject(root)
        case let .pullRequest(repo, n):
            let path = RecentProjects.repoRoot(of: repo) ?? Clones.find(repo) ?? Clones.ask(repo)
            guard let path else { return }
            app.viewPullRequest(n, repo: path) { error in
                if let error { DeepLinks.alert("Couldn't open #\(n)", error) }
            }
        case let .commit(repo, sha):
            guard let review = reviewFor(repo, app: app) else { return }
            var choice = review.choice
            choice.mode = .commit
            choice.commit = sha
            review.setChoice(choice)
        case let .file(repo, path, line):
            reviewFor(repo, app: app)?.whenLoaded { review in review.reveal(path: path, line: line) }
        case let .comment(repo, id):
            reviewFor(repo, app: app)?.whenLoaded { review in review.reveal(thread: id) }
        case let .web(url):
            NSWorkspace.shared.open(url)
        }
        NSApp.activateUnlessTesting()
    }

    /// The project's review, open and in front.
    private static func reviewFor(_ repo: String, app: AppDelegate) -> ReviewView? {
        guard let root = RecentProjects.repoRoot(of: repo) else { return nil }
        app.openProject(root)
        return app.front?.repoPath == root ? app.front?.review : nil
    }
}

extension ProjectWindowController {
    /// Where this window is, to come back to.
    var location: Destination {
        switch mode {
        case .agents: return .agents(session: StationHost.currentAgent?())
        case .pullRequests: return .pullRequests
        case .review: return location(inReview: true)
        }
    }
}
