import Foundation
import Observation
import onramp

/// Every Claude Code session on this Mac, live and past, from Claude Code's own transcripts
/// (~/.claude/projects/<folder>/<session id>.jsonl) plus the live state `station hook` keeps.
/// Each transcript is read once, then only what's been added since.
@MainActor
@Observable
final class SessionCatalog {
    static let shared = SessionCatalog()

    /// What a transcript says about its session.
    struct Info: Sendable, Equatable {
        var id: String
        var cwd: String?
        var branch: String?
        var title: String?        // Claude's own title for it
        var firstPrompt: String?
        var lastReply: String?
        var model: String?
        var started: Date?
        var lastActivity: Date?
        var inputTokens = 0, outputTokens = 0, cacheReadTokens = 0, cacheWriteTokens = 0
        var pr: (repo: String, number: Int, url: URL)?
        var turns = 0
        /// How it was started: "cli" (a terminal), "claude-desktop", "sdk-cli" (headless: `claude -p`,
        /// scripts, Station's own review sessions).
        var entrypoint: String?
        var isBackground: Bool { entrypoint == "sdk-cli" }
        var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
        static func == (a: Info, b: Info) -> Bool {
            a.id == b.id && a.entrypoint == b.entrypoint && a.title == b.title && a.lastActivity == b.lastActivity && a.totalTokens == b.totalTokens && a.pr?.number == b.pr?.number && a.branch == b.branch
        }
    }

    /// Token totals are the one thing that needs the whole file: counted in the background, kept
    /// in a cache so each launch only reads what's new.
    private struct Tally: Codable, Sendable {
        var offset: UInt64 = 0
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, turns = 0
        var lastMessage: String?
    }

    private(set) var sessions: [String: Info] = [:]
    /// For the perf test: passes run, and how long the last of each took (seconds).
    struct Timings { var scans = 0, lastScan = 0.0, counts = 0, lastCount = 0.0, files = 0 }
    @ObservationIgnored private(set) var timings = Timings()
    @ObservationIgnored private var tallies: [String: Tally] = [:]
    /// Each transcript's last skim, keyed by path: re-read only when its size or date moves.
    private struct Skim: Sendable { var size: Int; var modified: Date; var info: Info }
    @ObservationIgnored private var skims: [String: Skim] = [:]
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var counting = false
    @ObservationIgnored private var timer: Timer?
    /// How far back "Recent" goes.
    nonisolated static let window: TimeInterval = 14 * 24 * 3600

    nonisolated static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects") }
    /// In Caches, not ~/.config/station: that folder is watched for settings changes, and this
    /// file is rewritten every time a transcript grows. STATION_CACHE_DIR for tests.
    nonisolated private static var cacheURL: URL {
        let dir = ProcessInfo.processInfo.environment["STATION_CACHE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.timwheeler.station")
        return dir.appendingPathComponent("sessions-cache.json")
    }

    func start() {
        guard timer == nil else { return }
        try? FileManager.default.removeItem(at: OnrampHostSettingsDir.url.appendingPathComponent("sessions-cache.json")) // where 1.1 kept it
        tallies = (try? Data(contentsOf: Self.cacheURL)).flatMap { try? JSONDecoder().decode([String: Tally].self, from: $0) } ?? [:]
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in MainActor.assumeIsolated { SessionCatalog.shared.refresh() } }
    }

    /// The fast pass: each recent transcript's start and end (titles, folders, times, the last
    /// reply), then tokens in the background.
    func refresh() {
        guard !scanning else { return }
        scanning = true
        let tallies = self.tallies, known = self.skims
        DispatchQueue.global(qos: .utility).async {
            let began = DispatchTime.now()
            let files = Self.recentFiles()
            // Changed files are skimmed in parallel: a cold launch reads ~50 MB of transcripts.
            var fresh = [Info?](repeating: nil, count: files.count)
            let stale = files.indices.filter { let (f, m, n) = files[$0]; return !(known[f.path].map { $0.size == n && $0.modified == m } ?? false) }
            fresh.withUnsafeMutableBufferPointer { out in
                nonisolated(unsafe) let out = out
                DispatchQueue.concurrentPerform(iterations: stale.count) { k in
                    let (file, modified, _) = files[stale[k]]
                    var info = autoreleasepool { Self.skim(file) }
                    info.lastActivity = info.lastActivity ?? modified
                    out[stale[k]] = info
                }
            }
            var infos: [String: Info] = [:], skims: [String: Skim] = [:]
            for (n, (file, modified, size)) in files.enumerated() {
                guard var info = fresh[n] ?? known[file.path]?.info else { continue }
                skims[file.path] = Skim(size: size, modified: modified, info: info)
                if let t = tallies[file.path] {
                    info.inputTokens = t.input; info.outputTokens = t.output; info.cacheReadTokens = t.cacheRead; info.cacheWriteTokens = t.cacheWrite; info.turns = t.turns
                }
                infos[info.id] = info
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let catalog = SessionCatalog.shared
                    if infos != catalog.sessions { catalog.sessions = infos }
                    catalog.skims = skims
                    catalog.scanning = false
                    catalog.timings.scans += 1; catalog.timings.files = files.count
                    catalog.timings.lastScan = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1e9
                    catalog.count(files.map(\.0))
                }
            }
        }
    }

    /// Session transcripts only (`<project>/<id>.jsonl`; subagents' logs live deeper), newest first.
    nonisolated private static func recentFiles() -> [(URL, Date, Int)] {
        let fm = FileManager.default, cutoff = Date().addingTimeInterval(-window)
        var out: [(URL, Date, Int)] = []
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [] where file.pathExtension == "jsonl" {
                if let v = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]), let m = v.contentModificationDate, m > cutoff { out.append((file, m, v.fileSize ?? 0)) }
            }
        }
        return out.sorted { $0.1 > $1.1 }
    }

    /// Token totals, one file at a time, newest first; only the part not counted yet.
    private func count(_ files: [URL]) {
        guard !counting else { return }
        counting = true
        let known = tallies
        DispatchQueue.global(qos: .utility).async {
            let began = DispatchTime.now()
            let elapsed = { Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1e9 }
            var tallies = known
            var changed = false
            for file in files {
                let size = UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                var t = tallies[file.path] ?? Tally()
                if size < t.offset { t = Tally() } // rewritten: count again
                guard size > t.offset else { continue }
                autoreleasepool { Self.tally(file, into: &t) } // parsed JSON is autoreleased: free it per file, not per pass
                tallies[file.path] = t
                changed = true
            }
            guard changed else {
                let t = elapsed()
                DispatchQueue.main.async { MainActor.assumeIsolated { let c = SessionCatalog.shared; c.counting = false; c.timings.counts += 1; c.timings.lastCount = t } }
                return
            }
            try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(tallies).write(to: Self.cacheURL, options: .atomic)
            let took = elapsed()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let catalog = SessionCatalog.shared
                    catalog.tallies = tallies
                    catalog.counting = false
                    catalog.timings.counts += 1; catalog.timings.lastCount = took
                    var sessions = catalog.sessions
                    for file in files {
                        guard let t = tallies[file.path] else { continue }
                        let id = file.deletingPathExtension().lastPathComponent
                        sessions[id]?.inputTokens = t.input; sessions[id]?.outputTokens = t.output
                        sessions[id]?.cacheReadTokens = t.cacheRead; sessions[id]?.cacheWriteTokens = t.cacheWrite; sessions[id]?.turns = t.turns
                    }
                    if sessions != catalog.sessions { catalog.sessions = sessions }
                }
            }
        }
    }

    nonisolated private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated private static func lines(_ data: Data) -> [[String: Any]] {
        data.split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    nonisolated private static func chunk(_ file: URL, from offset: UInt64, length: Int) -> Data {
        guard let h = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        return (try? h.read(upToCount: length)) ?? Data()
    }

    /// Everything but the token totals, from the file's first 128 KB and last 512 KB.
    nonisolated private static func skim(_ file: URL) -> Info {
        var i = Info(id: file.deletingPathExtension().lastPathComponent)
        let size = UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var head = chunk(file, from: 0, length: 131_072)
        if let end = head.lastIndex(of: 0x0A) { head = head[..<end] }
        for e in lines(head) {
            if i.started == nil, let t = (e["timestamp"] as? String).flatMap(iso.date(from:)) { i.started = t }
            if i.cwd == nil { i.cwd = e["cwd"] as? String }
            if i.entrypoint == nil { i.entrypoint = e["entrypoint"] as? String }
            if i.firstPrompt == nil, e["type"] as? String == "user", let p = prompt(e) { i.firstPrompt = oneLine(p) }
        }
        let tailStart = size > 524_288 ? size - 524_288 : 0
        var tail = chunk(file, from: tailStart, length: 524_288)
        if tailStart > 0, let first = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: first)...] } // drop the partial first line
        for e in lines(tail) {
            if let t = (e["timestamp"] as? String).flatMap(iso.date(from:)) { i.lastActivity = t }
            if let cwd = e["cwd"] as? String { i.cwd = cwd }
            if let b = e["gitBranch"] as? String, !b.isEmpty { i.branch = b }
            switch e["type"] as? String {
            case "ai-title": i.title = e["aiTitle"] as? String ?? i.title
            case "pr-link":
                if let repo = e["prRepository"] as? String, let n = e["prNumber"] as? Int, let u = (e["prUrl"] as? String).flatMap(URL.init(string:)) { i.pr = (repo, n, u) }
            case "assistant":
                guard e["isSidechain"] as? Bool != true, let m = e["message"] as? [String: Any] else { break }
                if let model = m["model"] as? String, !model.hasPrefix("<") { i.model = model }
                let words = ((m["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: " ")
                if !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { i.lastReply = oneLine(words) }
            default: break
            }
        }
        return i
    }

    /// What you typed, if this entry is a prompt (not a tool result or a system note).
    nonisolated private static func prompt(_ e: [String: Any]) -> String? {
        guard e["isMeta"] as? Bool != true, e["isSidechain"] as? Bool != true, let m = e["message"] as? [String: Any] else { return nil }
        let text = (m["content"] as? String) ?? ((m["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String)
        guard let text, !text.isEmpty, !text.hasPrefix("<") else { return nil }
        return text
    }

    /// Add up tokens (each reply once: its blocks repeat the same usage) and prompts, from `t.offset`.
    nonisolated private static func tally(_ file: URL, into t: inout Tally) {
        guard let h = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: t.offset)
        while let data = try? h.read(upToCount: 4_194_304), !data.isEmpty {
            guard let end = data.lastIndex(of: 0x0A) else { break }
            let whole = data[data.startIndex...end]
            t.offset += UInt64(whole.count)
            for line in whole.split(separator: 0x0A) {
                // Cheap checks first: most lines are neither replies with usage nor prompts.
                let isReply = line.firstRange(of: Data(#""usage""#.utf8)) != nil
                let isUser = line.firstRange(of: Data(#""type":"user""#.utf8)) != nil
                guard isReply || isUser, let e = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if e["type"] as? String == "user", prompt(e) != nil { t.turns += 1; continue }
                guard e["type"] as? String == "assistant", let m = e["message"] as? [String: Any], let u = m["usage"] as? [String: Any] else { continue }
                let id = m["id"] as? String ?? e["requestId"] as? String
                if let id, id == t.lastMessage { continue }
                t.lastMessage = id
                t.input += u["input_tokens"] as? Int ?? 0
                t.output += u["output_tokens"] as? Int ?? 0
                t.cacheRead += u["cache_read_input_tokens"] as? Int ?? 0
                t.cacheWrite += u["cache_creation_input_tokens"] as? Int ?? 0
            }
            if whole.count < data.count { try? h.seek(toOffset: t.offset) } // re-read the partial line next time round
        }
    }

    nonisolated private static func oneLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }
}

/// Station's config folder (~/.config/station).
enum OnrampHostSettingsDir {
    nonisolated static var url: URL { OnrampHost.settingsURL.deletingLastPathComponent() }
}
