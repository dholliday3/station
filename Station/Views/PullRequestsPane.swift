import SwiftUI
import StoplightCore

/// The main window's Pull Requests tab: the panel's sections, full width.
struct PullRequestsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search pull requests", text: $model.searchText).textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
                if let t = model.lastRefresh {
                    Text("Updated \(t, style: .relative) ago").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if case .signedIn = model.auth {
                if model.sections.allSatisfy({ $0.prs.isEmpty }) {
                    Text(model.searchText.isEmpty ? "No open pull requests" : "No matches")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.sections) { sec in
                                if !sec.prs.isEmpty {
                                    let collapsed = model.isCollapsed(sec.id)
                                    SectionHeader(id: sec.id, title: sec.title, prs: sec.prs, collapsed: collapsed, mode: model.prefs.sectionCounts,
                                                  allCollapsed: model.sections.allSatisfy { model.prefs.collapsedSections.contains($0.id) },
                                                  url: sec.url,
                                                  toggle: { model.prefs.toggleCollapsed(sec.id) },
                                                  toggleAll: { _ = model.handle(.toggleSections) },
                                                  drop: { moving in
                                                      model.prefs.moveSection(moving, onto: sec.id, currentOrder: model.sectionIDs)
                                                      model.sourcesChanged()
                                                  })
                                    if !collapsed {
                                        let rows = Stacks.layout(sec.prs)
                                        ForEach(rows) { row in
                                            PRRow(pr: row.pr, model: model, section: sec, depth: row.depth,
                                                  stack: row.stackID.map { Stacks.members(of: $0, in: rows) })
                                            Divider()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                SignInView(model: model).frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refreshIfStale() }
    }
}
