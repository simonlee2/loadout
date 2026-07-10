import SwiftUI

/// Root three-column layout: sidebar filter, inventory matrix, and detail.
struct ContentView: View {
    let store: InventoryStore

    @State private var sidebarSelection: SidebarSelection = .allSkills
    @State private var selectedRowID: SkillRow.ID?
    @State private var searchText = ""

    /// Rows after applying the sidebar filter and the search field.
    private var visibleRows: [SkillRow] {
        store.rows.filter { matchesSidebar($0) && matchesSearch($0) }
    }

    private var selectedRow: SkillRow? {
        guard let selectedRowID else { return nil }
        return store.rows.first { $0.id == selectedRowID }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            VStack(spacing: 0) {
                MatrixView(
                    rows: visibleRows,
                    agents: store.activeAgents,
                    selection: $selectedRowID
                )
                Divider()
                StatusBarView(store: store)
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 620)
            .navigationTitle("Loadout")
        } detail: {
            DetailView(row: selectedRow)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search skills")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.rescan() }
                } label: {
                    if store.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.isScanning)
                .help("Rescan for installed skills")
            }
        }
        .task {
            await store.rescan()
        }
    }

    // MARK: Filtering

    private func matchesSidebar(_ row: SkillRow) -> Bool {
        switch sidebarSelection {
        case .allSkills:
            return true
        case .origin(let kind):
            return row.installations.contains { $0.origin.kind == kind }
        case .agent(let agent):
            return row.installation(for: agent) != nil
        }
    }

    private func matchesSearch(_ row: SkillRow) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let needle = query.lowercased()

        if row.slug.lowercased().contains(needle) { return true }
        if row.displayName.lowercased().contains(needle) { return true }
        if let summary = row.summary, summary.lowercased().contains(needle) { return true }

        return row.installations.contains { installation in
            if let name = installation.metadata.name, name.lowercased().contains(needle) {
                return true
            }
            if let description = installation.metadata.description,
               description.lowercased().contains(needle) {
                return true
            }
            return false
        }
    }
}
