import SwiftUI
import onramp

/// The review windows' settings: how the diff looks, comment sync, the agent session. They live
/// in settings.json, which the windows watch, so every change here applies straight away.
struct ReviewSettingsTab: View {
    private var file: SettingsFile { .shared }

    private func string(_ key: String, _ fallback: String) -> Binding<String> {
        Binding(get: { file.value(key) as? String ?? fallback }, set: { file.set(key, $0) })
    }
    private func bool(_ key: String, _ fallback: Bool) -> Binding<Bool> {
        Binding(get: { (file.value(key) as? NSNumber)?.boolValue ?? fallback }, set: { file.set(key, $0) })
    }
    private func number(_ key: String, _ fallback: Double) -> Binding<Double> {
        Binding(get: { (file.value(key) as? NSNumber)?.doubleValue ?? fallback }, set: { file.set(key, $0) })
    }

    var body: some View {
        Form {
            Section("Look") {
                Picker("Appearance", selection: string("appearance", "system")) {
                    Text("Match the system").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                themePicker("Light theme", key: "theme_light", dark: false)
                themePicker("Dark theme", key: "theme_dark", dark: true)
                Picker("Font", selection: string("font_family", "")) {
                    ForEach(OnrampHost.fontFamilies, id: \.self) { f in Text(f).tag(f == OnrampHost.fontFamilies.first ? "" : f) }
                }
                Stepper(value: number("font_size", 12.5), in: 9...24, step: 0.5) {
                    LabeledContent("Font size", value: String(format: "%g pt", number("font_size", 12.5).wrappedValue))
                }
                Toggle("Coding ligatures", isOn: bool("font_ligatures", true))
                    .help("-> => != drawn as one glyph, in fonts that have them.")
            }
            Section("Comments") {
                Toggle(isOn: bool("github_comments", true)) {
                    InfoLabel("Sync with GitHub on pull requests", "Your comments can go to the PR's GitHub review, and its GitHub threads come in. Each comment box still has Post to GitHub.")
                }
                Toggle(isOn: bool("ci_comments", true)) {
                    InfoLabel("Show CI failures as comments", "Failing check annotations appear as threads on the lines they point at.")
                }
            }
            Section("Agents") {
                Picker(selection: string("agent_session", "auto")) {
                    Text("Start with each review").tag("auto")
                    Text("Start when I ask").tag("manual")
                    Text("Off").tag("off")
                } label: {
                    InfoLabel("Claude session", "A Claude session primed on the diff answers comments in seconds. It runs while a review is open.")
                }
            }
            Section("Dock") {
                Toggle(isOn: Binding(get: { !bool("dock_icon", true).wrappedValue }, set: { file.set("dock_icon", !$0) })) {
                    InfoLabel("Hide the Dock icon", "Station lives in the menu bar only. Open windows from the dots' menu; the app menus (File, Edit…) aren't shown then.")
                }
            }
            Section {
                LabeledContent("settings.json") {
                    Button("Open") { NSWorkspace.shared.open(file.url) }
                        .help("Every setting in Station, as text. Edits apply as soon as you save.")
                }
            } footer: {
                Text(file.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            }
        }
        .formStyle(.grouped)
    }

    private func themePicker(_ title: String, key: String, dark: Bool) -> some View {
        let names = OnrampHost.themeNames(dark: dark)
        return Picker(title, selection: string(key, names.first ?? "")) {
            ForEach(names, id: \.self) { Text($0).tag($0) }
        }
    }
}
