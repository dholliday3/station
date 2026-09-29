import SwiftUI

/// What surrounds a review: its PR, the agents working on its branch, its CI. The host (Station)
/// knows these; the review asks through `StationHost.reviewContext` and redraws on `.contextChanged`.
public struct ReviewContext: Equatable, Sendable {
    public struct PR: Equatable, Sendable {
        public var repo: String, number: Int, title: String, url: URL, isDraft: Bool
        public init(repo: String, number: Int, title: String, url: URL, isDraft: Bool) {
            self.repo = repo; self.number = number; self.title = title; self.url = url; self.isDraft = isDraft
        }
    }
    public enum AgentState: String, Sendable { case needsYou, running, idle, ended }
    public struct Agent: Equatable, Sendable, Identifiable {
        public var id: String, title: String, state: AgentState
        public init(id: String, title: String, state: AgentState) { self.id = id; self.title = title; self.state = state }
    }
    public struct Checks: Equatable, Sendable {
        public enum State: Sendable { case passed, failed, running, skipped }
        public struct Item: Equatable, Sendable, Identifiable {
            public var name: String, state: State, url: URL?
            public var id: String { name }
            public init(name: String, state: State, url: URL?) { self.name = name; self.state = state; self.url = url }
        }
        public var passed: Int, failed: Int, running: Int
        public var url: URL?
        /// Each check, failures first.
        public var items: [Item] = []
        public var total: Int { passed + failed + running }
        public init(passed: Int, failed: Int, running: Int, url: URL?, items: [Item] = []) {
            self.passed = passed; self.failed = failed; self.running = running; self.url = url
            self.items = items.sorted { $0.state.rank < $1.state.rank }
        }
    }
    public var pr: PR?
    public var agents: [Agent] = []
    public var checks: Checks?
    public init(pr: PR? = nil, agents: [Agent] = [], checks: Checks? = nil) { self.pr = pr; self.agents = agents; self.checks = checks }
}

public extension Notification.Name {
    /// The host's agents, PRs or checks changed: context bars ask again.
    static let stationContextChanged = Notification.Name("station.contextChanged")
}

/// The bar's state; the review fills it in.
@MainActor
@Observable
final class ContextBarModel {
    var branch: String?
    var context = ReviewContext()
    var openComments = 0
    /// The review shows this PR (its chip then opens it on GitHub instead).
    var showingPR: Int?
    /// Failing checks CI turned into comments on this diff: check name → thread id.
    var ciThreads: [String: String] = [:]
    @ObservationIgnored var onShowThread: ((String) -> Void)?

    @ObservationIgnored var onPR: ((ReviewContext.PR) -> Void)?
    @ObservationIgnored var onAgent: ((String) -> Void)?
    @ObservationIgnored var onComments: (() -> Void)?
}

/// Across the top of a review: where you are and everything connected to it, each a link.
struct ContextBar: View {
    let model: ContextBarModel
    static let height: CGFloat = 34

    var body: some View {
        HStack(spacing: 6) {
            if let branch = model.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.trailing, 4)
            }
            if let pr = model.context.pr {
                Chip(help: model.showingPR == pr.number ? "Open #\(pr.number) on GitHub" : "Review #\(pr.number) in Station") { model.onPR?(pr) } label: {
                    Image(systemName: "arrow.triangle.pull").foregroundStyle(pr.isDraft ? Color.secondary : Color.green)
                    Text("#\(pr.number)").monospacedDigit()
                    Text(pr.title).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: 320)
            }
            if let checks = model.context.checks, checks.total > 0 {
                ChecksChip(checks: checks, ciThreads: model.ciThreads, onShowThread: { model.onShowThread?($0) })
            }
            ForEach(model.context.agents.prefix(3)) { agent in
                Chip(help: "\(agent.title): \(agent.state.word). Show in Agents") { model.onAgent?(agent.id) } label: {
                    AgentDot(state: agent.state)
                    Text(agent.title).lineLimit(1)
                    Text(agent.state.word).foregroundStyle(agent.state == .needsYou ? Color.orange : Color.secondary)
                }
                .frame(maxWidth: 260)
            }
            if model.context.agents.count > 3 {
                Chip(help: "More agents on this branch") { model.onAgent?(model.context.agents[3].id) } label: {
                    Text("+\(model.context.agents.count - 3)")
                }
            }
            Spacer(minLength: 8)
            if model.openComments > 0 {
                Chip(help: "Open comments on this diff") { model.onComments?() } label: {
                    Image(systemName: "text.bubble")
                    Text("\(model.openComments)").monospacedDigit()
                }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .animation(.snappy(duration: 0.25), value: model.context)
    }

}

extension ReviewContext.Checks.State {
    var rank: Int { switch self { case .failed: 0; case .running: 1; case .passed: 2; case .skipped: 3 } }
}

public extension ReviewContext.Checks {
    /// "2 failing", "5/12", "12 passed".
    var label: String {
        if failed > 0 { return "\(failed) failing" }
        if running > 0 { return "\(passed)/\(total)" }
        return "\(passed) passed"
    }
}

/// CI's chip: the ring and a count; click for every check.
public struct ChecksChip: View {
    let checks: ReviewContext.Checks
    var ciThreads: [String: String] = [:]
    var onShowThread: ((String) -> Void)?
    @State private var open = false

    public init(checks: ReviewContext.Checks, ciThreads: [String: String] = [:], onShowThread: ((String) -> Void)? = nil) {
        self.checks = checks; self.ciThreads = ciThreads; self.onShowThread = onShowThread
    }

    public var body: some View {
        Chip(help: "Checks: \(checks.passed) passed, \(checks.failed) failed, \(checks.running) running") { open.toggle() } label: {
            CheckRing(checks: checks)
            Text(checks.label).monospacedDigit().foregroundStyle(checks.failed > 0 ? Color.red : Color.primary)
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ChecksList(checks: checks, ciThreads: ciThreads, onShowThread: { id in open = false; onShowThread?(id) })
        }
    }
}

/// Every check: its state, its log, and for a failure CI left on a line, that line.
struct ChecksList: View {
    let checks: ReviewContext.Checks
    let ciThreads: [String: String]
    let onShowThread: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CheckRing(checks: checks)
                Text("Checks").font(.headline)
                Text("\(checks.passed) passed · \(checks.failed) failed · \(checks.running) running").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let u = checks.url { Button("All on GitHub") { Navigator.go(.web(u)) }.buttonStyle(.link).font(.caption) }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(checks.items) { item in
                        HStack(spacing: 8) {
                            icon(item.state)
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 12)
                            if item.state == .failed, let thread = ciThreads[item.name] {
                                Button("Show in diff") { onShowThread(thread) }.buttonStyle(.link).font(.caption)
                            }
                            if let u = item.url { Button("Log") { Navigator.go(.web(u)) }.buttonStyle(.link).font(.caption) }
                        }
                        .font(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 420)
    }

    @ViewBuilder private func icon(_ s: ReviewContext.Checks.State) -> some View {
        switch s {
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .running: ProgressView().controlSize(.small).frame(width: 14, height: 14)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

public extension ReviewContext.AgentState {
    var word: String {
        switch self { case .needsYou: "needs you"; case .running: "running"; case .idle: "idle"; case .ended: "done" }
    }
    var color: Color {
        switch self { case .needsYou: .orange; case .running: .blue; case .idle: .green; case .ended: .secondary }
    }
}

/// A capsule link: highlights on hover, shows the hand.
struct Chip<Content: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { label }
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(.primary.opacity(hover ? 0.12 : 0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0; if $0 { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}

/// CI as a ring: green fills as checks pass, red if any failed; spins while any are running.
public struct CheckRing: View {
    let checks: ReviewContext.Checks
    public init(checks: ReviewContext.Checks) { self.checks = checks }
    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        let done = Double(checks.passed + checks.failed) / Double(max(1, checks.total))
        let color: Color = checks.failed > 0 ? .red : checks.running > 0 ? .orange : .green
        ZStack {
            Circle().stroke(.primary.opacity(0.15), lineWidth: 2)
            Circle().trim(from: 0, to: done).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            if checks.running > 0 {
                Circle().trim(from: 0, to: 0.2).stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            } else if checks.failed == 0 {
                Image(systemName: "checkmark").font(.system(size: 6, weight: .heavy)).foregroundStyle(color)
            }
        }
        .frame(width: 12, height: 12)
        .animation(.snappy, value: done)
    }
}

/// A session's status: pulses while it's running, so a glance says "working".
public struct AgentDot: View {
    let state: ReviewContext.AgentState
    public init(state: ReviewContext.AgentState) { self.state = state }
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        Circle().fill(state.color)
            .frame(width: 7, height: 7)
            .overlay {
                if state == .running || state == .needsYou {
                    Circle().stroke(state.color, lineWidth: 1.5)
                        .scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 0.8)
                        .animation(reduceMotion ? nil : .easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
                        .onAppear { pulse = true }
                }
            }
    }
}
