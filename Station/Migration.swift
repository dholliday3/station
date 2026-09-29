import AppKit
import SwiftUI
import onramp

/// Bring over an Onramp and Stoplight setup, once, when you say so. The only code in Station that
/// reads the old names. Settings and review data are copied, never moved; the old commands and
/// agent registrations are replaced (they'd point at an app that's gone); the old apps go to the
/// Trash only if you tick it.
@MainActor
enum Migration {
    private static let decidedKey = "migration.decided"
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// What an Onramp and Stoplight setup left on this Mac.
    struct Found {
        var stoplight: [String: Any] = [:]
        var onramp: [String: Any] = [:]
        var onrampConfig: URL?
        /// Git dirs holding Onramp's review data (comments, the review's choice, context).
        var reviewData: [URL] = []
        /// ~/.local/bin/onramp and ramp, pointing into Onramp.app.
        var oldCommands: [URL] = []
        var apps: [URL] = []
        /// Filled in later: asking each agent's CLI takes a moment.
        var agents: [String]? = nil

        var isEmpty: Bool { stoplight.isEmpty && onramp.isEmpty && onrampConfig == nil && reviewData.isEmpty && oldCommands.isEmpty && apps.isEmpty }

        var stoplightSummary: String {
            var parts: [String] = []
            if let data = stoplight["sources"] as? Data, let s = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let n = { (k: String) in (s[k] as? [Any])?.count ?? 0 }
                let follows = n("followUsers") + n("followRepos") + n("followOrgs") + n("followBranches"), hides = n("hiddenRepos") + n("hiddenUsers")
                if follows > 0 { parts.append("\(follows) followed") }
                if hides > 0 { parts.append("\(hides) hidden") }
            }
            if let pins = stoplight["pinnedIDs"] as? [Any], !pins.isEmpty { parts.append("\(pins.count) pinned") }
            if stoplight["agent"] != nil || stoplight["terminal"] != nil { parts.append("agent and terminal choices") }
            return parts.isEmpty ? "Your settings" : parts.joined(separator: ", ")
        }
    }

    /// Everything Stoplight kept that UserPrefs still reads under the same key.
    private static let stoplightKeys: Set<String> = [
        "sources", "watchedRefs", "pinnedIDs", "ghPath", "showCountInMenuBar", "menuBarHousing", "colorProfile", "collapsedSections",
        "mergedDays", "branchCommits", "sectionOrder", "tourSeen", "rowActions", "rowActionsSeen", "sectionCounts", "agent",
        "agentCustomCommand", "agentPermissionMode", "agentReviewPermissionMode", "agentExtraArgs", "terminal", "agentPrompt",
        "agentReviewPrompt", "repoScanRoots", "repoScanRoot", "repoPaths", "primaryClick", "stackCopyOrder", "showQueues",
        "queueItems", "refreshSeconds", "notificationMode", "notifyReviews", "notifyComments", "notifyActivityOn",
        "ignoreBotActivity", "mutedAuthors", "panelSize", "panelHeightIsManual",
    ]

    private static func prefs(_ domain: String) -> [String: Any] {
        let keys = CFPreferencesCopyKeyList(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        guard !keys.isEmpty else { return [:] }
        return CFPreferencesCopyMultiple(keys as CFArray, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    static func find() -> Found {
        var f = Found()
        f.stoplight = prefs("com.timwheeler.stoplight").filter { stoplightKeys.contains($0.key) }
        f.onramp = prefs("com.timwheeler.onramp").filter { $0.key.hasPrefix("onramp.") || $0.key.contains(" onramp.") }
        let config = home.appendingPathComponent(".config/onramp")
        if FileManager.default.fileExists(atPath: config.path) { f.onrampConfig = config }
        for root in f.onramp["onramp.recentProjects"] as? [String] ?? [] {
            if let dir = gitDir(root)?.appendingPathComponent("onramp"), FileManager.default.fileExists(atPath: dir.path) { f.reviewData.append(dir) }
        }
        for name in ["onramp", "ramp"] {
            let link = home.appendingPathComponent(".local/bin/\(name)")
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), dest.contains("Onramp.app") { f.oldCommands.append(link) }
        }
        f.apps = ["/Applications/Onramp.app", "/Applications/Stoplight.app"].map(URL.init(fileURLWithPath:)).filter { FileManager.default.fileExists(atPath: $0.path) }
        return f
    }

    /// `<repo>/.git`, or where a worktree's `.git` file points.
    private static func gitDir(_ root: String) -> URL? {
        let dotGit = URL(fileURLWithPath: root).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8), let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: root)).standardizedFileURL
    }

    // MARK: Offering

    private static var window: NSWindow?

    /// At launch: once, if there's anything to bring over.
    static func offerIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: decidedKey), ProcessInfo.processInfo.environment["STATION_SELFTEST"] == nil else { return }
        let found = find()
        guard !found.isEmpty else { return UserDefaults.standard.set(true, forKey: decidedKey) }
        show(found)
    }

    /// From the menu, any time.
    static func offer() { show(find()) }

    private static func show(_ found: Found) {
        let model = MigrationModel(found: found)
        let w = NSWindow(contentViewController: NSHostingController(rootView: MigrationView(model: model)))
        w.title = "Welcome to Station"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activateUnlessTesting()
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let agents = OnrampHost.onrampAgentRegistrations()
            DispatchQueue.main.async { MainActor.assumeIsolated { model.found.agents = agents; model.moveAgents = !agents.isEmpty } }
        }
    }

    static func close(decided: Bool) {
        if decided { UserDefaults.standard.set(true, forKey: decidedKey) }
        window?.close()
        window = nil
    }

    // MARK: Bringing it over

    struct Choices { var settings = true, reviews = true, commands = true, agents = true, trash = true }

    /// Does what's chosen; returns one line per thing done (or not).
    static func run(_ f: Found, _ c: Choices) -> [String] {
        var done: [String] = []
        let fm = FileManager.default
        if c.settings {
            // Stoplight: through PrefsStore, so what belongs in settings.json lands there.
            for (key, value) in f.stoplight { PrefsStore.shared.set(value, forKey: key) }
            // Onramp: its app keys, renamed.
            for (key, value) in f.onramp { UserDefaults.standard.set(value, forKey: key.replacingOccurrences(of: "onramp.", with: "station.")) }
            // Onramp's settings.json, themes, extensions, reviewers and review context.
            if let config = f.onrampConfig {
                let station = OnrampHost.settingsURL.deletingLastPathComponent()
                if let data = try? Data(contentsOf: config.appendingPathComponent("settings.json")),
                   let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for (key, value) in old { SettingsFile.shared.set(key, value) }
                }
                for item in ["themes", "extensions", "reviewers", "context.json"] {
                    copyMissing(config.appendingPathComponent(item), to: station.appendingPathComponent(item))
                }
            }
            AppModel.shared.reloadPrefs()
            if !f.stoplight.isEmpty || !f.onramp.isEmpty || f.onrampConfig != nil { done.append("Settings brought over") }
        }
        if c.reviews {
            // Copy, never move: the old folder also holds agents' git worktrees, which git tracks by path.
            var n = 0
            for dir in f.reviewData {
                let dest = dir.deletingLastPathComponent().appendingPathComponent("station")
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                    guard (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { continue } // checkouts/: Station makes its own
                    let to = dest.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: to.path), (try? fm.copyItem(at: file, to: to)) != nil { n += 1 }
                }
            }
            if !f.reviewData.isEmpty { done.append("Review comments copied from \(f.reviewData.count) project\(f.reviewData.count == 1 ? "" : "s")" + (n == 0 ? " (Station already had them)" : "")) }
        }
        if c.commands {
            for link in f.oldCommands { try? fm.removeItem(at: link) }
            if OnrampHost.installCommand() { done.append("The station command is in ~/.local/bin" + (f.oldCommands.isEmpty ? "" : "; onramp and ramp are gone")) }
        }
        if c.trash {
            for id in ["com.timwheeler.onramp", "com.timwheeler.stoplight"] {
                NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
            }
            if !f.apps.isEmpty {
                NSWorkspace.shared.recycle(f.apps) { _, _ in }
                done.append("Onramp and Stoplight moved to the Trash")
            }
        }
        return done
    }

    /// Copy `from` to `to`, file by file, keeping anything already at `to`.
    private static func copyMissing(_ from: URL, to: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: from.path, isDirectory: &isDir) else { return }
        if !isDir.boolValue {
            if !fm.fileExists(atPath: to.path) { try? fm.copyItem(at: from, to: to) }
            return
        }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        for item in (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? [] {
            copyMissing(item, to: to.appendingPathComponent(item.lastPathComponent))
        }
    }
}

@MainActor
@Observable
final class MigrationModel {
    var found: Migration.Found
    var choices = Migration.Choices()
    var moveAgents = false
    var working = false
    var result: [String]?

    init(found: Migration.Found) { self.found = found }

    func bringOver() {
        working = true
        var lines = Migration.run(found, choices)
        guard moveAgents, found.agents?.isEmpty == false else { return finish(lines) }
        DispatchQueue.global(qos: .userInitiated).async {
            let problems = OnrampHost.switchAgentsFromOnramp()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    lines.append(problems.isEmpty ? "Agents now use station" : "Agents: " + problems.joined(separator: "; "))
                    self.finish(lines)
                }
            }
        }
    }

    private func finish(_ lines: [String]) {
        working = false
        result = lines.isEmpty ? ["Nothing needed bringing over"] : lines
    }
}

/// "Bring over your Onramp and Stoplight setup?" One row per thing found, each with its own box.
struct MigrationView: View {
    @Bindable var model: MigrationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result = model.result {
                Text("You're set").font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result, id: \.self) { Label($0, systemImage: "checkmark.circle.fill").foregroundStyle(.primary) }
                }
                Text("Two things only you can do: add the Station widget (the old one can't move), and check the panel shows the people you follow.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Done") { Migration.close(decided: true) }.keyboardShortcut(.defaultAction) }
            } else {
                Text("Bring over your Onramp and Stoplight setup?").font(.title2.weight(.semibold))
                Text("Station found them on this Mac. Settings and comments are copied, never moved. The old commands and agent connections are replaced by Station's.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    if !model.found.stoplight.isEmpty || !model.found.onramp.isEmpty || model.found.onrampConfig != nil {
                        Toggle(isOn: $model.choices.settings) { row("Settings", model.found.stoplight.isEmpty ? "Onramp's settings, themes and review context" : "Stoplight: \(model.found.stoplightSummary). Onramp: settings, themes, recent projects.") }
                    }
                    if !model.found.reviewData.isEmpty {
                        Toggle(isOn: $model.choices.reviews) { row("Review comments", "From \(model.found.reviewData.count) project\(model.found.reviewData.count == 1 ? "" : "s"), copied into each repo's .git/station") }
                    }
                    Toggle(isOn: $model.choices.commands) { row("The station command", model.found.oldCommands.isEmpty ? "In ~/.local/bin" : "Replaces onramp and ramp in ~/.local/bin") }
                    if let agents = model.found.agents {
                        if !agents.isEmpty { Toggle(isOn: $model.moveAgents) { row("Your agents", "\(agents.joined(separator: ", ")): switch from onramp to station") } }
                    } else {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking your agents…").font(.callout).foregroundStyle(.secondary) }
                    }
                    if !model.found.apps.isEmpty {
                        Toggle(isOn: $model.choices.trash) { row("Move Onramp and Stoplight to the Trash", "Quits them first. You can put them back from the Trash.") }
                    }
                }
                Text("The widget can't move: add Station's after.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Start Fresh") { Migration.close(decided: true) }
                    Spacer()
                    if model.working { ProgressView().controlSize(.small) }
                    Button("Bring It Over") { model.bringOver() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.working)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.body.weight(.medium))
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
