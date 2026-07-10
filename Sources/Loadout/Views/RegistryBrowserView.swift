import SwiftUI

// MARK: - Browser (content column)

/// Content column shown when the sidebar selects a registry. Loads featured
/// content on appear and drives `RegistryStore.search` from the shared
/// `.searchable` field (debounced). Selecting a row fills the detail column.
struct RegistryBrowserView: View {
    let registryID: String
    let store: RegistryStore
    /// The shared toolbar search text; empty means "show featured".
    let searchText: String
    @Binding var selection: RegistrySkill.ID?

    private var state: RegistryStore.BrowseState {
        store.browse[registryID] ?? RegistryStore.BrowseState()
    }

    var body: some View {
        content
            .task(id: BrowseKey(registry: registryID, query: searchText)) {
                await loadContent()
            }
    }

    @ViewBuilder
    private var content: some View {
        if state.isLoading && state.skills.isEmpty {
            ProgressView("Loading skills…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = state.error, state.skills.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Load Registry", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") {
                    Task { await loadContent(force: true) }
                }
            }
        } else if state.skills.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No Featured Skills" : "No Results",
                systemImage: "shippingbox",
                description: Text(
                    searchText.isEmpty
                        ? "This registry has nothing to show yet."
                        : "No skills match “\(searchText)”."
                )
            )
        } else {
            List(state.skills, selection: $selection) { skill in
                RegistrySkillRow(skill: skill, store: store)
                    .tag(skill.id)
            }
            .listStyle(.inset)
        }
    }

    /// Debounced routing for the shared search field. Empty query → featured;
    /// otherwise wait ~300ms (cancelled if the key changes) then search.
    private func loadContent(force: Bool = false) async {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            await store.loadFeatured(registry: registryID)
        } else {
            if !force {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            await store.search(trimmed, registry: registryID)
        }
    }
}

/// Composite `task(id:)` key so either a registry switch or a keystroke
/// re-triggers loading (and cancels an in-flight debounce).
private struct BrowseKey: Hashable {
    let registry: String
    let query: String
}

// MARK: - Row

private struct RegistrySkillRow: View {
    let skill: RegistrySkill
    let store: RegistryStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.headline)
                        .lineLimit(1)
                    if skill.slug != skill.name {
                        Text(skill.slug)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if let summary = skill.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if let count = skill.installCount {
                        Label(RegistryFormat.installs(count), systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let version = skill.version {
                        RegistryChip(text: version)
                    }
                    AuditChip(status: skill.audit)
                }
            }

            Spacer(minLength: 8)

            RegistryInstallControl(skill: skill, store: store)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail column

/// Detail column for the registry browser: the selected skill, or an empty state.
struct RegistryDetailView: View {
    let skill: RegistrySkill?
    let store: RegistryStore

    var body: some View {
        if let skill {
            RegistrySkillDetail(skill: skill, store: store)
                .id(skill.id)
        } else {
            ContentUnavailableView(
                "No Skill Selected",
                systemImage: "sidebar.right",
                description: Text("Select a skill from the registry to see its details.")
            )
        }
    }
}

private struct RegistrySkillDetail: View {
    let skill: RegistrySkill
    let store: RegistryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(skill.name)
                        .font(.title2.weight(.semibold))
                    if skill.slug != skill.name {
                        Text(skill.slug)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 6) {
                        RegistryChip(text: skill.registry, symbol: "shippingbox")
                        if let version = skill.version {
                            RegistryChip(text: version)
                        }
                        AuditChip(status: skill.audit)
                    }
                    RegistryInstallControl(skill: skill, store: store)
                        .padding(.top, 4)
                }

                Divider()

                if let summary = skill.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary").font(.headline)
                        Text(summary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Details").font(.headline)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                        detailRow("Registry", skill.registry)
                        detailRow("Identifier", skill.identifier)
                        if let version = skill.version {
                            detailRow("Version", version)
                        }
                        if let count = skill.installCount {
                            detailRow("Installs", RegistryFormat.installs(count))
                        }
                        detailRow("Audit", auditLabel)
                    }
                    .font(.callout)
                }

                if let url = skill.sourceURL {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source").font(.headline)
                        Link(destination: url) {
                            Label(url.absoluteString, systemImage: "link")
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(skill.name)
    }

    private var auditLabel: String {
        switch skill.audit {
        case .passed: "Passed"
        case .flagged: "Flagged"
        case .unknown, nil: "Not audited"
        }
    }

    private func detailRow(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Install control

/// The trailing install affordance, reused in the row and the detail pane:
/// an "Install…" button opening a per-agent popover, a spinner while
/// installing, or a disabled "Installed ✓" once present in the library.
struct RegistryInstallControl: View {
    let skill: RegistrySkill
    let store: RegistryStore

    @State private var showingPopover = false
    @State private var chosenAgents: Set<AgentID> = Set(AgentID.allCases)

    var body: some View {
        if store.isInstalled(skill) {
            Label("Installed", systemImage: "checkmark")
                .font(.callout)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        } else if store.isInstalling(skill) {
            ProgressView()
                .controlSize(.small)
        } else {
            Button("Install…") { showingPopover = true }
                .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                    popover
                }
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install to")
                .font(.headline)
            ForEach(AgentID.allCases) { agent in
                Toggle(agent.displayName, isOn: Binding(
                    get: { chosenAgents.contains(agent) },
                    set: { include in
                        if include { chosenAgents.insert(agent) }
                        else { chosenAgents.remove(agent) }
                    }
                ))
            }
            HStack {
                Spacer()
                Button("Install") {
                    let agents = AgentID.allCases.filter { chosenAgents.contains($0) }
                    showingPopover = false
                    Task { await store.install(skill, to: agents) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosenAgents.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 220)
    }
}

// MARK: - Chips + formatting

/// Neutral capsule chip matching the matrix's `OriginChip` style.
struct RegistryChip: View {
    let text: String
    var symbol: String?

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let symbol { Image(systemName: symbol) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
    }
}

/// Green "Passed" / orange "Flagged" pill; hidden when unknown or absent.
struct AuditChip: View {
    let status: AuditStatus?

    var body: some View {
        switch status {
        case .passed:
            chip("Passed", color: .green, symbol: "checkmark.shield")
        case .flagged:
            chip("Flagged", color: .orange, symbol: "exclamationmark.shield")
        case .unknown, nil:
            EmptyView()
        }
    }

    private func chip(_ text: String, color: Color, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

enum RegistryFormat {
    /// "12.4k installs", "1 install", "0 installs".
    static func installs(_ count: Int) -> String {
        let noun = count == 1 ? "install" : "installs"
        if count >= 1000 {
            let thousands = Double(count) / 1000
            return String(format: "%.1fk \(noun)", thousands)
        }
        return "\(count) \(noun)"
    }
}
