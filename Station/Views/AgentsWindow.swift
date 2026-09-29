import AppKit
import SwiftUI
import StationKit

/// ⌘⇧A: every Claude Code session, live and past. What needs you first, then what's running,
/// what's idle (finished a turn, waiting for your next prompt), then recent ones that ended.
@MainActor
enum AgentsWindow {
    private static var window: NSWindow?

    /// The main window's Agents tab when a window is open, else this standalone window.
    static func present() {
        if !StationHost.show(.agents) { show() }
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
        NSApp.activateUnlessTesting()
        window?.present()
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
    /// Shared, so links (Navigator: station://agents/<id>) can pick the session shown.
    @Bindable private var picked = AgentsSelection.shared
    private var selection: String? { get { picked.id } nonmutating set { picked.id = newValue } }
    @State private var search = ""
    @AppStorage("agents.showBackground") private var showBackground = false
    private var board: AgentBoard { .shared }

    /// Headless sessions that ended (scripts, `claude -p`, Station's own review sessions).
    private var hiddenBackground: Int { AgentSession.all().filter { $0.status == .ended && $0.info?.isBackground == true }.count }

    private var sessions: [AgentSession] {
        let all = AgentSession.all().filter { showBackground || !($0.status == .ended && $0.info?.isBackground == true) }
        let filter = AgentFilter(search)
        return filter.isEmpty ? all : all.filter(filter.matches)
    }

    var body: some View {
        let list = sessions
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header(list)
                if !board.installed { offer }
                Divider()
                List(selection: $picked.id) {
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
            chip("\(count(.needsYou)) need you", .orange, on: count(.needsYou) > 0, token: "is:needs-you")
            chip("\(count(.running)) running", .blue, on: count(.running) > 0, token: "is:running")
            chip("\(count(.idle)) idle", .green, on: count(.idle) > 0, token: "is:idle")
            Spacer()
            TextField("Filter: words, is:running, repo:, branch:, pr:, model:", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .safeAreaInset(edge: .bottom, spacing: 0) { suggestionRow }
    }

    /// Chips completing the filter being typed: prefixes, then values your sessions have.
    @ViewBuilder private var suggestionRow: some View {
        let chips = AgentFilter.suggestions(for: search, sessions: AgentSession.all())
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { c in
                        Button { search = AgentFilter.complete(search, with: c) } label: {
                            Text(c).font(.caption2).monospaced().foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 8)
        }
    }

    /// A status count that filters to it (click again to clear).
    private func chip(_ text: String, _ color: Color, on: Bool, token: String) -> some View {
        let active = AgentFilter(search).tokens.contains(token)
        return Button { search = AgentFilter.toggle(token, in: search) } label: {
            Text(text).font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(on || active ? color : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill((on || active ? color : Color.secondary).opacity(active ? 0.3 : 0.12)))
                .overlay(Capsule().strokeBorder(active ? color : .clear))
        }
        .buttonStyle(.plain)
        .help(active ? "Show all" : "Show only these (\(token))")
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
        if let root = session.checkout { Button("Review Its Changes") { StationHost.go(.review(repo: root)) } }
        if let pr = session.info?.pr {
            Button("Review PR #\(pr.number)") {
                if NSEvent.modifierFlags.contains(.option) { NSWorkspace.shared.open(pr.url) } else { StationHost.go(.pullRequest(repo: pr.repo, number: pr.number)) }
            }
            .help("Its diff in Station (⌥-click: on GitHub)")
        }
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
                if let pr = session.info?.pr { PRLink(pr: pr, checkout: session.checkout) }
                ForEach(session.editedByCheckout, id: \.root) { group in EditedFiles(root: group.root, files: group.files) }

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

/// Which session the Agents tab shows. Links set it; the tab's list follows.
@MainActor
@Observable
final class AgentsSelection {
    static let shared = AgentsSelection()
    var id: String?
}

/// Which git checkout a path is in: the nearest folder up with a .git (a folder, or a worktree's
/// .git file). A file-system walk, no git; remembered.
@MainActor
enum Checkouts {
    private static var roots: [String: String] = [:]

    static func root(of path: String) -> String? {
        var dir = (path as NSString).standardizingPath
        var seen: [String] = []
        while dir != "/" && !dir.isEmpty {
            if let known = roots[dir] { seen.forEach { roots[$0] = known }; return known }
            seen.append(dir)
            if FileManager.default.fileExists(atPath: dir + "/.git") { seen.forEach { roots[$0] = dir }; return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}

extension AgentSession {
    /// The files it edited, by checkout (worktrees apart), most-edited checkout first.
    @MainActor var editedByCheckout: [(root: String, files: [String])] {
        var groups: [String: [String]] = [:]
        for path in info?.edited ?? [] {
            guard let root = Checkouts.root(of: path) else { continue }
            groups[root, default: []].append(String(path.dropFirst(root.count + 1)))
        }
        return groups.map { ($0.key, $0.value) }.sorted { $0.1.count > $1.1.count }
    }

    /// Where its work is: the checkout it edited most, else the one it runs in.
    @MainActor var checkout: String? { editedByCheckout.first?.root ?? (cwd.isEmpty ? nil : Checkouts.root(of: cwd)) }
}

/// The session's PR: a link to its diff in Station, with CI as a live ring.
private struct PRLink: View {
    let pr: (repo: String, number: Int, url: URL)
    let checkout: String?

    var body: some View {
        let context = ReviewContextProvider.context(repo: checkout ?? "", slug: pr.repo, branch: nil, pr: pr.number)
        HStack(spacing: 8) {
            Button {
                if NSEvent.modifierFlags.contains(.option) { NSWorkspace.shared.open(pr.url) } else { StationHost.go(.pullRequest(repo: pr.repo, number: pr.number)) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.pull").foregroundStyle(.green)
                    Text("\(pr.repo)#\(pr.number)").monospacedDigit()
                    if let title = context.pr?.title { Text(title).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .buttonStyle(.link)
            .help("Its diff in Station (⌥-click: on GitHub)")
            if let checks = context.checks, checks.total > 0 { ChecksChip(checks: checks) }
        }
        .font(.callout)
    }
}

/// "Edited in <checkout>": each file opens in Station's review of that checkout.
private struct EditedFiles: View {
    let root: String
    let files: [String]
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Edited in \((root as NSString).lastPathComponent)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(files.count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                Spacer()
                Button("Review") { StationHost.go(.review(repo: root)) }.buttonStyle(.link).font(.caption)
            }
            ForEach(showAll ? files : Array(files.prefix(12)), id: \.self) { file in
                Button { StationHost.go(.file(repo: root, path: file, line: nil)) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc").foregroundStyle(.tertiary)
                        Text((file as NSString).lastPathComponent)
                        Text((file as NSString).deletingLastPathComponent).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(file) in the review")
            }
            if files.count > 12 {
                Button(showAll ? "Show fewer" : "Show all \(files.count)") { showAll.toggle() }.buttonStyle(.link).font(.caption)
            }
        }
    }
}

/// The Agents filter: words match the title, first prompt, project and branch; is:running,
/// is:needs-you, is:idle, is:ended, is:live, is:background; repo:, branch:, pr:, model:.
struct AgentFilter {
    private(set) var tokens: [String] = []
    private var words: [String] = []
    var isEmpty: Bool { tokens.isEmpty && words.isEmpty }

    static let prefixes = ["is:", "repo:", "branch:", "pr:", "model:"]
    static let states = ["running", "needs-you", "idle", "ended", "live", "background"]

    init(_ text: String) {
        for raw in text.lowercased().split(separator: " ").map(String.init) {
            if Self.prefixes.contains(where: { raw.hasPrefix($0) && raw.count > $0.count }) { tokens.append(raw) } else { words.append(raw) }
        }
    }

    func matches(_ s: AgentSession) -> Bool {
        let hay = "\(s.title) \(s.project) \(s.info?.branch ?? "") \(s.info?.firstPrompt ?? "")".lowercased()
        guard words.allSatisfy(hay.contains) else { return false }
        // Same prefix: any of them (is:running is:idle); different prefixes: all.
        let byPrefix = Dictionary(grouping: tokens) { t in Self.prefixes.first { t.hasPrefix($0) }! }
        return byPrefix.allSatisfy { prefix, values in
            values.contains { t in
                let v = String(t.dropFirst(prefix.count))
                switch prefix {
                case "is:":
                    switch v {
                    case "running": return s.status == .running
                    case "needs-you": return s.status == .needsYou
                    case "idle": return s.status == .idle || s.status == .ready
                    case "ended": return s.status == .ended
                    case "live": return s.status != .ended
                    case "background": return s.info?.isBackground == true
                    default: return false
                    }
                case "repo:": return s.project.lowercased().contains(v) || (s.info?.pr?.repo.lowercased().contains(v) ?? false)
                case "branch:": return s.info?.branch?.lowercased().contains(v) ?? false
                case "pr:": return s.info?.pr.map { String($0.number) == v.trimmingCharacters(in: CharacterSet(charactersIn: "#")) } ?? false
                case "model:": return s.model?.lowercased().replacingOccurrences(of: " ", with: "-").contains(v) ?? false
                default: return false
                }
            }
        }
    }

    /// What to offer for the token being typed.
    static func suggestions(for text: String, sessions: [AgentSession]) -> [String] {
        let last = text.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init)?.lowercased() ?? ""
        guard !text.isEmpty else { return [] }
        func pick(_ prefix: String, _ values: [String]) -> [String] {
            let partial = String(last.dropFirst(prefix.count))
            let uniq = (NSOrderedSet(array: values.filter { !$0.isEmpty }).array as? [String]) ?? []
            return uniq.filter { partial.isEmpty || $0.lowercased().contains(partial) }.prefix(10).map { prefix + $0 }
        }
        switch true {
        case last.hasPrefix("is:"): return pick("is:", states)
        case last.hasPrefix("repo:"): return pick("repo:", sessions.map(\.project))
        case last.hasPrefix("branch:"): return pick("branch:", sessions.compactMap { $0.info?.branch })
        case last.hasPrefix("pr:"): return pick("pr:", sessions.compactMap { $0.info?.pr.map { String($0.number) } })
        case last.hasPrefix("model:"): return pick("model:", sessions.compactMap { $0.model?.replacingOccurrences(of: " ", with: "-") })
        case last.isEmpty || !last.contains(":"): return prefixes.filter { last.isEmpty || $0.hasPrefix(last) }
        default: return []
        }
    }

    /// `text` with its last token replaced by `chip` (and a space after a finished value).
    static func complete(_ text: String, with chip: String) -> String {
        var parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if parts.isEmpty { parts = [""] }
        parts[parts.count - 1] = chip
        return parts.joined(separator: " ") + (chip.hasSuffix(":") ? "" : " ")
    }

    /// Add or remove one token.
    static func toggle(_ token: String, in text: String) -> String {
        var parts = text.split(separator: " ").map(String.init)
        if let i = parts.firstIndex(where: { $0.lowercased() == token }) { parts.remove(at: i) } else { parts.append(token) }
        return parts.joined(separator: " ") + (parts.isEmpty ? "" : " ")
    }
}
