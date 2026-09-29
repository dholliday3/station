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
        StationHost.paletteAgents = {
            AgentSession.all().filter { $0.status != .ended || !($0.info?.isBackground ?? false) }.prefix(200).map { s in
                let branch = s.info?.branch.map { " · \($0)" } ?? ""
                let status = s.status == .ended ? (s.info?.lastActivity.map { "ended \($0.formatted(.relative(presentation: .named)))" } ?? "ended") : s.status.word
                return (id: s.id, title: s.title, subtitle: "Agent · \(s.project)\(branch) · \(status)",
                        search: "agent " + (s.info?.firstPrompt ?? "") + " " + (s.info?.pr.map { "#\($0.number)" } ?? ""),
                        live: s.status != .ended)
            }
        }
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
                let items = pr.checks.map { c in
                    let state: ReviewContext.Checks.State = switch c.state {
                    case .success: .passed
                    case .failure: .failed
                    case .pending: .running
                    case .skipped: .skipped
                    }
                    return ReviewContext.Checks.Item(name: c.name, state: state, url: c.url)
                }
                out.checks = .init(passed: passed, failed: failed, running: pr.checks.count - passed - failed, url: pr.checksURL, items: items)
            }
        }
        out.agents = agents(repo: repo, branch: branch, slug: slug, pr: pr?.number ?? number)
        return out
    }

    /// Sessions that worked on this diff: linked to its PR, or edited files in this very checkout
    /// (not a worktree nested inside it) — on this branch, when they run in this checkout (a
    /// transcript's branch is its own checkout's). Station's own background review sessions
    /// don't count. Live first, then the most recent.
    private static func agents(repo: String, branch: String?, slug: String?, pr: Int?) -> [ReviewContext.Agent] {
        let root = (repo as NSString).standardizingPath
        let order: [AgentSession.Status: Int] = [.needsYou: 0, .running: 1, .idle: 2, .ready: 3, .ended: 4]
        return AgentSession.all()
            .filter { s in
                guard let info = s.info, !info.isBackground else { return s.live != nil && Checkouts.root(of: s.cwd) == root }
                // Linked to this PR (it made it, or worked on it).
                if let pr, let slug, let p = info.pr, p.number == pr, p.repo.caseInsensitiveCompare(slug) == .orderedSame { return true }
                guard info.edited.contains(where: { Checkouts.root(of: $0) == root }) else { return false }
                // Its transcript's branch is its own checkout's: it says something here only if that's this one.
                let runsHere = Checkouts.root(of: s.cwd) == root
                return !runsHere || s.status != .ended || branch == nil || info.branch == nil || info.branch == branch
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
