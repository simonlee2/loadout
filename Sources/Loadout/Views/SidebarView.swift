import SwiftUI

/// Left column: a Library section (all skills + one row per origin kind present)
/// and an Agents section. Selection drives the matrix filter.
struct SidebarView: View {
    let store: InventoryStore
    let registryStore: RegistryStore
    let needsAttentionCount: Int
    @Binding var selection: SidebarSelection

    private var rows: [SkillRow] { store.rows }

    /// Origin kinds that actually appear, in canonical order.
    private var presentOriginKinds: [OriginKind] {
        let present = Set(store.installations.map { $0.origin.kind })
        return OriginKind.allCases.filter { present.contains($0) }
    }

    private func originCount(_ kind: OriginKind) -> Int {
        store.installations.filter { $0.origin.kind == kind }.count
    }

    private func agentCount(_ agent: AgentID) -> Int {
        store.installations.filter { $0.agent == agent }.count
    }

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                sidebarRow(
                    title: "All Skills",
                    symbol: "square.grid.2x2",
                    count: rows.count,
                    tag: .allSkills
                )

                sidebarRow(
                    title: "Needs Attention",
                    symbol: "exclamationmark.triangle",
                    count: needsAttentionCount,
                    tag: .needsAttention
                )

                ForEach(presentOriginKinds) { kind in
                    sidebarRow(
                        title: kind.label,
                        symbol: kind.symbol,
                        count: originCount(kind),
                        tag: .origin(kind)
                    )
                }
            }

            if !store.activeAgents.isEmpty {
                Section("Agents") {
                    ForEach(store.activeAgents) { agent in
                        sidebarRow(
                            title: agent.displayName,
                            symbol: agent.symbol,
                            count: agentCount(agent),
                            tag: .agent(agent)
                        )
                    }
                }
            }

            if !store.projects.isEmpty {
                Section("Projects") {
                    ForEach(store.projects) { project in
                        Label(project.name, systemImage: "folder")
                            .tag(SidebarSelection.project(path: project.path))
                            .help(project.path)
                    }
                }
            }

            if !registryStore.adapters.isEmpty {
                Section("Registries") {
                    ForEach(registryStore.adapters, id: \.id) { adapter in
                        Label(adapter.displayName, systemImage: "shippingbox")
                            .tag(SidebarSelection.registry(id: adapter.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Loadout")
    }

    private func sidebarRow(
        title: String,
        symbol: String,
        count: Int,
        tag: SidebarSelection
    ) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
        }
        .tag(tag)
    }
}
