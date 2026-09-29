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
        public var passed: Int, failed: Int, running: Int
        public var url: URL?
        public var total: Int { passed + failed + running }
        public init(passed: Int, failed: Int, running: Int, url: URL?) { self.passed = passed; self.failed = failed; self.running = running; self.url = url }
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

    @ObservationIgnored var onPR: ((ReviewContext.PR) -> Void)?
    @ObservationIgnored var onAgent: ((String) -> Void)?
    @ObservationIgnored var onChecks: ((ReviewContext.Checks) -> Void)?
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
                Chip(help: "Checks: \(checks.passed) passed, \(checks.failed) failed, \(checks.running) running") { model.onChecks?(checks) } label: {
                    CheckRing(checks: checks)
                    Text(checksLabel(checks)).monospacedDigit()
                }
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

    private func checksLabel(_ c: ReviewContext.Checks) -> String {
        if c.failed > 0 { return "\(c.failed) failing" }
        if c.running > 0 { return "\(c.passed)/\(c.total)" }
        return "\(c.passed) passed"
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
private struct Chip<Content: View>: View {
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
