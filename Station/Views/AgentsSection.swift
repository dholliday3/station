import SwiftUI

/// The panel's first section: every Claude Code session on this Mac, the ones waiting on you
/// first. Hidden when none are running; a one-line offer to turn it on until you do.
struct AgentsSection: View {
    private var board: AgentBoard { .shared }
    @AppStorage("agentsOfferDismissed") private var offerDismissed = false

    private static var claudeInstalled: Bool {
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)
    }

    var body: some View {
        if !board.installed {
            if !offerDismissed && Self.claudeInstalled { offer }
        } else if !board.agents.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                header
                ForEach(board.agents) { AgentRow(agent: $0, branch: board.branches[$0.cwd]) }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)
            Divider().padding(.horizontal, 12)
        }
    }

    private var header: some View {
        let needs = board.needsYou, working = board.agents.filter { $0.state == .working }.count
        return HStack(spacing: 6) {
            Text("Agents").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if needs > 0 { Text("\(needs) need\(needs == 1 ? "s" : "") you").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange) }
            if working > 0 { Text("\(working) working").font(.system(size: 11)).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var offer: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            Text("See every Claude Code session here").font(.system(size: 12))
            Spacer()
            Button("Turn On") { board.turnOn() }
                .controlSize(.small)
                .help("Adds Station's hooks to ~/.claude/settings.json (your other hooks stay). Turn off in Settings → Agent.")
            Button { offerDismissed = true } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.borderless)
                .help("Not now (Settings → Agent has it)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }
}

private struct AgentRow: View {
    let agent: AgentBoard.Agent
    let branch: String?
    @State private var hovering = false

    private var color: Color {
        switch agent.state {
        case .needsYou: .orange
        case .working: .blue
        case .done: .green
        case .ready: .secondary
        }
    }

    private var line: String {
        switch agent.state {
        case .needsYou: agent.detail ?? "Waiting on you"
        case .working: agent.detail ?? agent.task ?? "Working"
        case .done: "Done" + (agent.task.map { " · \($0)" } ?? "")
        case .ready: "Ready for a prompt"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AgentDot(color: color, pulsing: agent.state == .working).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(agent.project).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let branch, !branch.isEmpty, branch != "HEAD" {
                        Text(branch).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(Self.elapsed(since: agent.since)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text(line).font(.system(size: 11.5))
                    .foregroundStyle(agent.state == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1).truncationMode(.tail)
                    .help(agent.task ?? line)
            }
            if hovering {
                HStack(spacing: 2) {
                    if agent.state == .done {
                        Button { AgentBoard.shared.review(agent) } label: { Image(systemName: "doc.text.magnifyingglass") }
                            .help("Review what it changed")
                    }
                    Button { AgentBoard.shared.focus(agent) } label: { Image(systemName: "arrow.up.forward.app") }
                        .help("Go to its terminal")
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { AgentBoard.shared.focus(agent) }
        .help("\(agent.agent) in \(agent.cwd)")
    }

    /// "now", "4m", "2h", "3d".
    static func elapsed(since: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(since)))
        return s < 60 ? "now" : s < 3600 ? "\(s / 60)m" : s < 86400 ? "\(s / 3600)h" : "\(s / 86400)d"
    }
}

private struct AgentDot: View {
    let color: Color
    let pulsing: Bool
    @State private var dim = false

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .opacity(pulsing && dim ? 0.35 : 1)
            .animation(pulsing ? .easeInOut(duration: 1).repeatForever() : .default, value: dim)
            .onAppear { dim = pulsing }
            .onChange(of: pulsing) { _, p in dim = p }
    }
}
