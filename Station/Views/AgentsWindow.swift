import AppKit
import SwiftUI
import onramp

/// ⌘⇧A: every Claude Code session, live and past. What needs you first, then what's running,
/// what's idle (finished a turn, waiting for your next prompt), then recent ones that ended.
@MainActor
enum AgentsWindow {
    private static var window: NSWindow?

    /// The main window's Agents tab when a window is open, else this standalone window.
    static func present() {
        if !OnrampHost.show(.agents) { show() }
    }

    static func show() {
        SessionCatalog.shared.start()
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: AgentsView()))
            w.title = "Agents"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 980, height: 620))
            w.setFrameAutosaveName("station.agents")
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// One session as the window shows it: the transcript's facts plus, while it runs, its live state.
struct AgentSession: Identifiable, Equatable {
    enum Status: Int, CaseIterable {
        case needsYou, running, idle, ready, ended
        var title: String {
            switch self { case .needsYou: "Needs you"; case .running: "Running"; case .idle: "Idle"; case .ready: "Ready"; case .ended: "Recent" }
        }
        var color: Color {
            switch self { case .needsYou: .orange; case .running: .blue; case .idle: .green; case .ready: .secondary; case .ended: Color.secondary.opacity(0.5) }
        }
        var word: String {
            switch self { case .needsYou: "needs you"; case .running: "running"; case .idle: "idle"; case .ready: "ready"; case .ended: "ended" }
        }
    }

    let id: String
    let status: Status
    let info: SessionCatalog.Info?
    let live: AgentBoard.Agent?

    var cwd: String { live?.cwd ?? info?.cwd ?? "" }
    var project: String { cwd.isEmpty ? "?" : (cwd as NSString).lastPathComponent }
    var title: String { info?.title ?? live?.task ?? info?.firstPrompt ?? "Untitled session" }
    /// When it got to where it is now.
    var since: Date { live?.since ?? info?.lastActivity ?? .distantPast }
    /// What it's doing, asking, or last said.
    var line: String? {
        switch status {
        case .needsYou: live?.detail ?? "Waiting on you"
        case .running: live?.detail ?? "Working"
        case .idle: live?.summary ?? info?.lastReply
        case .ready: "Ready for a prompt"
        case .ended: info?.lastReply
        }
    }
    var model: String? {
        guard let m = info?.model else { return nil }
        // "claude-opus-5-5" → "opus 5.5"
        let parts = m.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return m }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return version.isEmpty ? String(family) : "\(family) \(version)"
    }

    static func == (a: AgentSession, b: AgentSession) -> Bool { a.id == b.id && a.status == b.status && a.info == b.info && a.live == b.live }

    /// Everything, sorted into its sections: live state wins over the transcript's.
    @MainActor static func all() -> [AgentSession] {
        let live = Dictionary(AgentBoard.shared.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let infos = SessionCatalog.shared.sessions
        return Set(live.keys).union(infos.keys).map { id -> AgentSession in
            let l = live[id]
            let status: Status = switch l?.state {
            case .needsYou?: .needsYou
            case .working?: .running
            case .done?: .idle
            case .ready?: .ready
            case nil: .ended
            }
            return AgentSession(id: id, status: status, info: infos[id], live: l)
        }
        .sorted { ($0.status.rawValue, $1.since) < ($1.status.rawValue, $0.since) }
    }
}

struct AgentsView: View {
    @State private var selection: String?
    @State private var search = ""
    @AppStorage("agents.showBackground") private var showBackground = false
    private var board: AgentBoard { .shared }

    /// Headless sessions that ended (scripts, `claude -p`, Station's own review sessions).
    private var hiddenBackground: Int { AgentSession.all().filter { $0.status == .ended && $0.info?.isBackground == true }.count }

    private var sessions: [AgentSession] {
        let all = AgentSession.all().filter { showBackground || !($0.status == .ended && $0.info?.isBackground == true) }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { "\($0.title) \($0.project) \($0.info?.branch ?? "") \($0.info?.firstPrompt ?? "")".lowercased().contains(q) }
    }

    var body: some View {
        let list = sessions
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header(list)
                if !board.installed { offer }
                Divider()
                List(selection: $selection) {
                    ForEach(AgentSession.Status.allCases, id: \.self) { status in
                        let rows = list.filter { $0.status == status }
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { SessionRow(session: $0).tag($0.id) }
                            } header: {
                                Text("\(status.title) · \(rows.count)").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(status == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .overlay { if list.isEmpty { Text(search.isEmpty ? "No Claude Code sessions in the last two weeks" : "Nothing matches").foregroundStyle(.secondary) } }
                if hiddenBackground > 0 || showBackground {
                    Divider()
                    Toggle("Show background sessions (\(hiddenBackground))", isOn: $showBackground)
                        .toggleStyle(.checkbox).font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("Sessions nobody typed into: `claude -p`, scripts, and Station's own review sessions")
                }
            }
            .frame(minWidth: 420, idealWidth: 520)
            Divider()
            Group {
                if let s = list.first(where: { $0.id == selection }) {
                    SessionDetail(session: s)
                } else {
                    Text("Select a session").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 440)
        .onAppear {
            SessionCatalog.shared.start()
            if selection == nil { selection = list.first?.id }
        }
    }

    private func header(_ list: [AgentSession]) -> some View {
        let count = { (s: AgentSession.Status) in list.filter { $0.status == s }.count }
        return HStack(spacing: 10) {
            chip("\(count(.needsYou)) need you", .orange, on: count(.needsYou) > 0)
            chip("\(count(.running)) running", .blue, on: count(.running) > 0)
            chip("\(count(.idle)) idle", .green, on: count(.idle) > 0)
            Spacer()
            TextField("Search sessions", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func chip(_ text: String, _ color: Color, on: Bool) -> some View {
        Text(text).font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(on ? color : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill((on ? color : Color.secondary).opacity(0.12)))
    }

    private var offer: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.secondary)
            Text("Turn on live status to see what's running and what needs you, as it happens.").font(.callout)
            Spacer()
            Button("Turn On") { board.turnOn() }.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }
}

private struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(session.status.color).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if session.info?.isBackground == true {
                        Text("background").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                    Spacer(minLength: 6)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(Self.when(session)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    Text(session.project).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    if let b = session.info?.branch, b != "HEAD" { Text(b).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
                    if let pr = session.info?.pr { Text("#\(pr.number)").font(.system(size: 11.5)).foregroundStyle(.tertiary) }
                    Spacer(minLength: 0)
                    if let out = session.info?.outputTokens, out > 0 {
                        Text(Self.tokens(out) + " out").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                            .help("Tokens it wrote. Its full use (cache reads re-send the same context) is in the details.")
                    }
                }
                if let line = session.line {
                    Text(line).font(.system(size: 11.5)).lineLimit(1)
                        .foregroundStyle(session.status == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
            }
        }
        .padding(.vertical, 3)
        .contextMenu { SessionActions(session: session) }
    }

    /// "running 4m", "idle 12m", "2h ago".
    static func when(_ s: AgentSession) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(s.since)))
        let span = secs < 60 ? "now" : secs < 3600 ? "\(secs / 60)m" : secs < 86400 ? "\(secs / 3600)h" : "\(secs / 86400)d"
        if s.status == .ended { return secs < 60 ? "just now" : "\(span) ago" }
        return secs < 60 ? s.status.word : "\(s.status.word) \(span)"
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}

/// What you can do with a session: the same list in the detail pane and a row's right-click menu.
private struct SessionActions: View {
    let session: AgentSession

    var body: some View {
        if let live = session.live {
            Button("Go to Terminal") { AgentBoard.shared.focus(live) }
        } else if !session.cwd.isEmpty {
            Button("Resume in Terminal") {
                Task { try? await AgentLauncher.runInTerminal("claude --resume \(session.id)", directory: session.cwd, title: "Resume · \(session.project)") }
            }
        }
        if !session.cwd.isEmpty { Button("Review Its Changes") { OnrampHost.openProject(session.cwd) } }
        if let pr = session.info?.pr { Button("Open PR #\(pr.number)") { NSWorkspace.shared.open(pr.url) } }
        Button("Copy Session ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.id, forType: .string) }
    }
}

private struct SessionDetail: View {
    let session: AgentSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Circle().fill(session.status.color).frame(width: 10, height: 10)
                    Text(session.status == .ended ? "Ended" : session.status.word.capitalized).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(session.status == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                Text(session.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if let line = session.line, session.status != .ended {
                    Text(line).font(.callout).foregroundStyle(session.status == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) { SessionActions(session: session) }.buttonStyle(.bordered).controlSize(.small)

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    fact("Folder", session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    if let b = session.info?.branch { fact("Branch", b) }
                    if let pr = session.info?.pr { fact("Pull request", "\(pr.repo)#\(pr.number)") }
                    if let m = session.model { fact("Model", m) }
                    if let i = session.info, i.totalTokens > 0 {
                        fact("Tokens", "\(i.inputTokens.formatted()) in · \(i.outputTokens.formatted()) out · \(i.cacheReadTokens.formatted()) cache read · \(i.cacheWriteTokens.formatted()) cache write")
                    }
                    if let t = session.info?.turns, t > 0 { fact("Prompts", "\(t)") }
                    if let s = session.info?.started { fact("Started", s.formatted(date: .abbreviated, time: .shortened)) }
                    if let l = session.info?.lastActivity { fact("Last activity", l.formatted(date: .abbreviated, time: .shortened)) }
                }
                .font(.callout)
                if let p = session.info?.firstPrompt { quote("First prompt", p) }
                if let r = session.info?.lastReply { quote("Last reply", r) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }

    private func quote(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
