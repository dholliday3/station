import AppKit
import Observation
import StationKit
import StoplightCore

/// Answers a review's "what's around me?": its PR and CI (from the PRs the menu bar polls) and the
/// agents on its branch (live sessions and recent transcripts). Tells reviews when any of it moves.
@MainActor
enum ReviewContextProvider {
    static func start() {
        StationHost.reviewContext = { repo, slug, branch, pr in context(repo: repo, slug: slug, branch: branch, pr: pr) }
        watch()
    }

    static func context(repo: String, slug: String?, branch: String?, pr number: Int?) -> ReviewContext {
        var out = ReviewContext()
        let prs = AppModel.shared.all
        let pr = slug.flatMap { slug in
            prs.first { p in
                guard p.repo.caseInsensitiveCompare(slug) == .orderedSame, !p.isBranch else { return false }
                if let number { return p.number == number }
                return p.headRefName == branch
            }
        }
        if let pr {
            out.pr = .init(repo: pr.repo, number: pr.number, title: pr.title, url: pr.url, isDraft: pr.isDraft)
            if !pr.checks.isEmpty {
                let passed = pr.checks.filter { $0.state == .success || $0.state == .skipped }.count
                let failed = pr.checks.filter { $0.state == .failure }.count
                out.checks = .init(passed: passed, failed: failed, running: pr.checks.count - passed - failed, url: pr.checksURL)
            }
        }
        out.agents = agents(repo: repo, branch: branch)
        return out
    }

    /// Sessions that worked here: edited files or worked in folders inside this checkout (agents
    /// often run from the main checkout and work in its .claude/worktrees), or sit in it on the
    /// same branch. Live first, then the most recent. The one that wrote the diff still
    /// counts once it's finished.
    private static func agents(repo: String, branch: String?) -> [ReviewContext.Agent] {
        let root = (repo as NSString).standardizingPath
        let order: [AgentSession.Status: Int] = [.needsYou: 0, .running: 1, .idle: 2, .ready: 3, .ended: 4]
        return AgentSession.all()
            .filter { s in
                // What it touched: files it edited or folders it worked in, inside this checkout.
                let inside = { (p: String) in let p = (p as NSString).standardizingPath; return p == root || p.hasPrefix(root + "/") }
                if let info = s.info, info.edited.contains(where: inside) || info.folders.contains(where: inside) { return true }
                let cwd = (s.cwd as NSString).standardizingPath
                guard !cwd.isEmpty else { return false }
                let sameBranch = branch != nil && s.info?.branch == branch
                if cwd == root || cwd.hasPrefix(root + "/") { return s.info?.branch == nil || branch == nil || sameBranch }
                return root.hasPrefix(cwd + "/") && sameBranch
            }
            .sorted { (order[$0.status] ?? 9, $1.since) < (order[$1.status] ?? 9, $0.since) }
            .map { s in
                let state: ReviewContext.AgentState = switch s.status {
                case .needsYou: .needsYou
                case .running: .running
                case .idle, .ready: .idle
                case .ended: .ended
                }
                return .init(id: s.id, title: s.title, state: state)
            }
    }

    /// Post `.stationContextChanged` (once per burst) when agents, sessions or PRs change.
    private static func watch() {
        withObservationTracking {
            _ = AgentBoard.shared.agents
            _ = SessionCatalog.shared.sessions
            _ = AppModel.shared.all
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NotificationCenter.default.post(name: .stationContextChanged, object: nil)
                    watch()
                }
            }
        }
    }
}

/// Which Claude Code session goes with which PR ("owner/name#123" → the liveliest, latest one),
/// from the PR links in transcripts. PR rows read it; rebuilt when sessions change.
@MainActor
@Observable
final class AgentIndex {
    static let shared = AgentIndex()
    private(set) var byPR: [String: ReviewContext.Agent] = [:]

    func agent(for pr: PullRequest) -> ReviewContext.Agent? { byPR["\(pr.repo.lowercased())#\(pr.number)"] }

    func start() { rebuild() }

    private func rebuild() {
        let order: [AgentSession.Status: Int] = [.needsYou: 0, .running: 1, .idle: 2, .ready: 3, .ended: 4]
        var out: [String: (Int, Date, ReviewContext.Agent)] = [:]
        withObservationTracking {
            for s in AgentSession.all() {
                guard let pr = s.info?.pr else { continue }
                let key = "\(pr.repo.lowercased())#\(pr.number)"
                let rank = order[s.status] ?? 9
                if let have = out[key], (have.0, -have.1.timeIntervalSince1970) <= (rank, -s.since.timeIntervalSince1970) { continue }
                let state: ReviewContext.AgentState = switch s.status {
                case .needsYou: .needsYou
                case .running: .running
                case .idle, .ready: .idle
                case .ended: .ended
                }
                out[key] = (rank, s.since, .init(id: s.id, title: s.title, state: state))
            }
        } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { AgentIndex.shared.rebuild() } }
        }
        let next = out.mapValues(\.2)
        if next != byPR { byPR = next }
    }
}
