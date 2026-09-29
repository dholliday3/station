import Foundation
import Observation
import onramp

/// settings.json: what you choose on purpose, in one file you can also edit by hand. The review
/// windows keep their settings in it too (they merge their keys, as this does), and each side
/// watches it, so a hand edit applies straight away.
@MainActor
@Observable
final class SettingsFile {
    static let shared = SettingsFile(url: OnrampHostSettings.url)

    let url: URL
    private(set) var values: [String: Any] = [:]
    /// The bytes we last wrote: a change to exactly these is our own echo, not an edit.
    @ObservationIgnored private var lastWritten: Data?
    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    /// A hand edit (or the review windows' settings) changed the file.
    @ObservationIgnored var onChange: (() -> Void)?

    init(url: URL) {
        self.url = url
        values = Self.read(url)
        watch()
    }

    func value(_ key: String) -> Any? { values[key] }

    /// Set (nil: remove) one key. Re-reads first so the other side's keys and hand edits survive.
    func set(_ key: String, _ value: Any?) {
        var now = Self.read(url)
        if let value, let old = now[key] as? NSObject, old.isEqual(value) { values = now; return }
        if value == nil, now[key] == nil { values = now; return }
        now[key] = value
        values = now
        guard let data = try? JSONSerialization.data(withJSONObject: now, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        lastWritten = data
        try? data.write(to: url, options: .atomic)
    }

    private static func read(_ url: URL) -> [String: Any] {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// The folder (a save that replaces the file) and the file (one that writes it in place).
    private func watch() {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        watchers.forEach { $0.cancel() }
        watchers = [dir, url].compactMap { target in
            let fd = open(target.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { self.fileChanged() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }

    private func fileChanged() {
        watch() // a replaced file is a new file: watch that one
        guard let data = try? Data(contentsOf: url), data != lastWritten else { return }
        let fresh = Self.read(url)
        guard !NSDictionary(dictionary: fresh).isEqual(to: values) else { return }
        values = fresh
        onChange?()
    }
}

/// Where the file is (the review windows' settings file: one file for the whole app).
enum OnrampHostSettings {
    static var url: URL { OnrampHost.settingsURL }
}

/// Where UserPrefs keeps each setting: the ones you choose on purpose in settings.json, the ones
/// the app remembers for you (panel layout, pins, what you've seen) in UserDefaults. Same calls
/// as UserDefaults, so UserPrefs reads and writes as it always did.
@MainActor
final class PrefsStore {
    static let shared = PrefsStore(defaults: .standard, file: .shared)

    let defaults: UserDefaults
    let file: SettingsFile?

    /// UserDefaults key → settings.json key.
    static let fileKeys: [String: String] = [
        "sources": "sources", Prefs.ghPath: "gh_path", Prefs.notifications: "notifications",
        Prefs.showCount: "menu_bar_count", Prefs.housing: "menu_bar_housing", Prefs.colorProfile: "color_profile",
        "mergedDays": "merged_days", "branchCommits": "branch_commits", "sectionCounts": "section_counts",
        "rowActions": "row_buttons", "primaryClick": "row_click", "stackCopyOrder": "stack_copy_order",
        "showQueues": "show_queues", "queueItems": "queue_items", "refreshSeconds": "refresh_seconds",
        "agent": "agent", "agentCustomCommand": "agent_custom_command", "agentPermissionMode": "agent_permission_mode",
        "agentReviewPermissionMode": "agent_review_permission_mode", "agentExtraArgs": "agent_extra_args",
        "terminal": "terminal", "agentPrompt": "agent_prompt", "agentReviewPrompt": "agent_review_prompt",
        "repoScanRoots": "repo_scan_roots",
        "notifyReviews": "notify_reviews", "notifyComments": "notify_comments", "notifyActivityOn": "notify_on",
        "ignoreBotActivity": "ignore_bots", "mutedAuthors": "mute",
    ]

    init(defaults: UserDefaults, file: SettingsFile?) {
        self.defaults = defaults
        self.file = file
    }

    private func fileKey(_ key: String) -> String? { file == nil ? nil : Self.fileKeys[key] }

    func object(forKey key: String) -> Any? {
        guard let k = fileKey(key) else { return defaults.object(forKey: key) }
        return file?.value(k)
    }
    func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }

    /// JSON blobs (the sources lists) live in the file as real JSON, snake_case at the top level.
    func data(forKey key: String) -> Data? {
        guard let k = fileKey(key) else { return defaults.data(forKey: key) }
        guard let obj = file?.value(k) as? [String: Any] else { return nil }
        return try? JSONSerialization.data(withJSONObject: Self.rekey(obj, Self.camel))
    }

    func set(_ value: Any?, forKey key: String) {
        guard let k = fileKey(key), let file else { return defaults.set(value, forKey: key) }
        if let data = value as? Data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return file.set(k, Self.rekey(obj, Self.snake))
        }
        file.set(k, value)
    }

    func removeObject(forKey key: String) {
        guard let k = fileKey(key), let file else { return defaults.removeObject(forKey: key) }
        file.set(k, nil)
    }

    private static func rekey(_ d: [String: Any], _ f: (String) -> String) -> [String: Any] {
        Dictionary(d.map { (f($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
    }
    private static func snake(_ s: String) -> String {
        s.reduce(into: "") { out, c in if c.isUppercase { out += "_" + c.lowercased() } else { out.append(c) } }
    }
    private static func camel(_ s: String) -> String {
        let parts = s.split(separator: "_")
        return (parts.first.map(String.init) ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}
