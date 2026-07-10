import SwiftUI
import UniformTypeIdentifiers

/// Left column: a Library section (all skills + one row per origin kind present)
/// and an Agents section. Selection drives the matrix filter.
struct SidebarView: View {
    let store: InventoryStore
    let registryStore: RegistryStore

    @State private var isAddingRegistry = false
    let needsAttentionCount: Int
    @Binding var selection: SidebarSelection

    /// Drives the "Add project folder…" picker hosted on this view.
    @State private var isAddingProject = false

    private var rows: [SkillRow] { store.rows }

    private var showHiddenProjects: Bool {
        store.projectPreferences?.showHidden ?? false
    }

    /// Project items after applying the "show hidden" preference.
    private var visibleProjectItems: [InventoryStore.ProjectItem] {
        store.projectItems.filter { showHiddenProjects || !$0.isHidden }
    }

    private var hiddenProjectCount: Int {
        store.projectItems.count { $0.isHidden }
    }

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

            Section {
                ForEach(visibleProjectItems) { item in
                    projectRow(item)
                }
                if hiddenProjectCount > 0 {
                    showHiddenToggle
                }
            } header: {
                projectsHeader
            }

            Section {
                ForEach(registryStore.adapters, id: \.id) { adapter in
                    Label(adapter.displayName, systemImage: "shippingbox")
                        .tag(SidebarSelection.registry(id: adapter.id))
                        .contextMenu {
                            if registryStore.canRemoveRegistry(id: adapter.id) {
                                Button("Remove Registry", role: .destructive) {
                                    if selection == .registry(id: adapter.id) {
                                        selection = .allSkills
                                    }
                                    registryStore.removeRegistry(id: adapter.id)
                                }
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Registries")
                    Spacer()
                    Button {
                        isAddingRegistry = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Add a git repo as a registry…")
                }
            }
        }
        .sheet(isPresented: $isAddingRegistry) {
            AddRegistrySheet(registryStore: registryStore)
        }
        .listStyle(.sidebar)
        .navigationTitle("Loadout")
        .fileImporter(
            isPresented: $isAddingProject,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case .success(let url):
                store.addManualProject(url)
            case .failure(let error):
                store.lastActionError = error.localizedDescription
            }
        }
    }

    // MARK: - Projects section

    private var projectsHeader: some View {
        HStack {
            Text("Projects")
            Spacer()
            Button {
                isAddingProject = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Add project folder…")
        }
    }

    private func projectRow(_ item: InventoryStore.ProjectItem) -> some View {
        Label(item.ref.name, systemImage: symbol(for: item))
            .foregroundStyle(item.isHidden ? Color.secondary : Color.primary)
            .tag(SidebarSelection.project(path: item.ref.path))
            .help(item.ref.path)
            .contextMenu {
                if item.isHidden {
                    Button("Unhide Project") {
                        store.unhideProject(item.ref.path)
                    }
                } else {
                    Button("Hide Project") {
                        hide(item)
                    }
                }
                if item.isManual {
                    Divider()
                    Button("Remove from List") {
                        remove(item)
                    }
                }
            }
    }

    private var showHiddenToggle: some View {
        Toggle(isOn: Binding(
            get: { showHiddenProjects },
            set: { store.setShowHiddenProjects($0) }
        )) {
            Text("Show Hidden (\(hiddenProjectCount))")
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func symbol(for item: InventoryStore.ProjectItem) -> String {
        if item.isHidden { return "eye.slash" }
        return item.isManual ? "plus.rectangle.on.folder" : "folder"
    }

    /// Hides a project, resetting the selection when the hidden project was
    /// selected and hidden rows aren't being shown (so it vanishes).
    private func hide(_ item: InventoryStore.ProjectItem) {
        store.hideProject(item.ref.path)
        if !showHiddenProjects, isSelected(item) {
            selection = .allSkills
        }
    }

    /// Removes a manual project, resetting the selection if it was selected
    /// (the row disappears entirely).
    private func remove(_ item: InventoryStore.ProjectItem) {
        store.removeManualProject(item.ref.path)
        if isSelected(item) {
            selection = .allSkills
        }
    }

    private func isSelected(_ item: InventoryStore.ProjectItem) -> Bool {
        if case .project(let path) = selection { return path == item.ref.path }
        return false
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

/// Sheet for adding a git repo (company or personal) as a registry.
private struct AddRegistrySheet: View {
    let registryStore: RegistryStore

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlString = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Git Registry")
                .font(.headline)
            Text("Any git repo with skills works — a plugin marketplace or a plain folder of skills. Private repos use your normal git login.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Name", text: $name, prompt: Text("Team Skills"))
                TextField("Git URL", text: $urlString, prompt: Text("https://github.com/org/skills.git"))
                    .textContentType(.URL)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    registryStore.addGitMarketplace(name: name, urlString: urlString)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                    || urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
