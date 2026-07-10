import SwiftUI
import AppKit

/// Right column: everything about the selected skill row. Reads the SKILL.md
/// file for the chosen installation at display time (read-only).
struct DetailView: View {
    let row: SkillRow?
    let store: InventoryStore
    let registryStore: RegistryStore

    var body: some View {
        if let row {
            SkillDetailView(row: row, store: store, registryStore: registryStore)
                .id(row.id)
        } else {
            ContentUnavailableView(
                "No Skill Selected",
                systemImage: "sidebar.right",
                description: Text("Select a skill from the matrix to see its details.")
            )
        }
    }
}

/// UI state for the SKILL.md body, adding a `.loading` phase to `SkillDocument`.
private enum DocumentState {
    case loading
    case missing
    case attributed(AttributedString)
    case plain(String)

    init(_ document: SkillDocument) {
        switch document {
        case .missing: self = .missing
        case .attributed(let value): self = .attributed(value)
        case .plain(let value): self = .plain(value)
        }
    }
}

private struct SkillDetailView: View {
    let row: SkillRow
    let store: InventoryStore
    let registryStore: RegistryStore

    @State private var selectedAgent: AgentID?
    @State private var document: DocumentState = .loading
    @State private var confirmingUninstall = false
    @State private var adopting = false
    @State private var reviewingUpdate = false

    /// Newer upstream version for this row, when `checkForUpdates` found one.
    private var availableUpdate: String? {
        registryStore.updatesAvailable[row.slug]
    }

    /// The currently-managed version, for the review sheet's "old → new" header.
    private var managedVersion: String? {
        registryStore.lockEntries.first { $0.slug == row.slug }?.version
    }

    /// Agents that don't yet have this skill — candidates for "sync to".
    private var otherAgents: [AgentID] {
        let present = Set(row.installations.map(\.agent))
        return AgentID.allCases.filter { !present.contains($0) }
    }

    /// Adopt is offered only for skills that are entirely user-scoped and not
    /// already tracked by the library.
    private var canAdopt: Bool {
        row.installations.allSatisfy { $0.origin == .user }
            && !registryStore.lockEntries.contains { $0.slug == row.slug }
    }

    /// The installation whose file we're viewing. Falls back to the first.
    private var installation: SkillInstallation? {
        if let selectedAgent, let match = row.installation(for: selectedAgent) {
            return match
        }
        return row.installations.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                if row.installations.count > 1 {
                    installationPicker
                }
                bodySection
                if let installation, !installation.metadata.extra.isEmpty {
                    metadataSection(installation.metadata.extra)
                }
                if let installation {
                    pathSection(installation)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(row.displayName)
        .task(id: row.id) {
            // Reset the file picker when the selected row changes.
            selectedAgent = row.installations.first?.agent
        }
        .task(id: installation?.id) {
            await loadDocument()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.displayName)
                .font(.title2.weight(.semibold))
            Text(row.slug)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            FlowChips(installations: row.installations)

            if let installation {
                actionsRow(installation)
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func actionsRow(_ installation: SkillInstallation) -> some View {
        HStack(spacing: 12) {
            SkillEnableToggle(installation: installation, store: store, showsLabel: true)

            if let update = availableUpdate {
                Button {
                    reviewingUpdate = true
                } label: {
                    Label("Review Update \(RowStatus.shortVersion(update))", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }

            if canAdopt {
                Button("Adopt & Sync…") {
                    adopting = true
                }
                .disabled(store.isScanning)
            }

            if store.canUninstall(installation) {
                Button("Uninstall…", role: .destructive) {
                    confirmingUninstall = true
                }
                .disabled(store.isScanning)
            }

            Spacer()
        }
        .padding(.top, 4)
        .sheet(isPresented: $adopting) {
            AdoptSheet(
                installation: installation,
                otherAgents: otherAgents,
                registryStore: registryStore
            )
        }
        .sheet(isPresented: $reviewingUpdate) {
            UpdateReviewSheet(
                slug: row.slug,
                oldVersion: managedVersion,
                registryStore: registryStore
            )
        }
        .confirmationDialog(
            "Move \(installation.slug) to Loadout's shelf?",
            isPresented: $confirmingUninstall,
            titleVisibility: .visible
        ) {
            Button("Move to Shelf", role: .destructive) {
                Task { await store.uninstall(installation) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files are kept and this can be reverted from History.")
        }
    }

    // MARK: Installation picker

    private var installationPicker: some View {
        Picker("Viewing", selection: $selectedAgent) {
            ForEach(row.installations) { installation in
                Text(installation.agent.displayName)
                    .tag(Optional(installation.agent))
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }

    // MARK: Body

    @ViewBuilder
    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SKILL.md")
                .font(.headline)

            switch document {
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .missing:
                Label("SKILL.md could not be read.", systemImage: "doc.questionmark")
                    .foregroundStyle(.secondary)
            case .attributed(let attributed):
                Text(attributed)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .plain(let raw):
                Text(raw)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Metadata

    private func metadataSection(_ extra: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(extra.keys.sorted(), id: \.self) { key in
                    GridRow {
                        Text(key)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(extra[key] ?? "")
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
        }
    }

    // MARK: Path + actions

    private func pathSection(_ installation: SkillInstallation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Location")
                .font(.headline)
            Text(installation.directory.path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)

            HStack {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([installation.directory])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }

                Button {
                    let file = installation.directory.appendingPathComponent("SKILL.md")
                    NSWorkspace.shared.open(file)
                } label: {
                    Label("Open SKILL.md", systemImage: "doc.text")
                }
            }
        }
    }

    // MARK: Loading

    private func loadDocument() async {
        guard let installation else {
            document = .missing
            return
        }
        document = .loading
        document = DocumentState(await SkillDocumentLoader.load(directory: installation.directory))
    }
}

/// Confirmation sheet for adopting an unmanaged skill into Loadout's library,
/// with optional additional agents to link it into.
private struct AdoptSheet: View {
    let installation: SkillInstallation
    let otherAgents: [AgentID]
    let registryStore: RegistryStore

    @Environment(\.dismiss) private var dismiss
    @State private var selectedAgents: Set<AgentID> = []
    @State private var isAdopting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adopt \(installation.displayName)")
                .font(.title3.weight(.semibold))

            Text("Moves the skill into Loadout's library and links it back — agents see the identical files. Optionally also link it into:")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if otherAgents.isEmpty {
                Text("Every agent already has this skill.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(otherAgents) { agent in
                        Toggle(agent.displayName, isOn: Binding(
                            get: { selectedAgents.contains(agent) },
                            set: { on in
                                if on { selectedAgents.insert(agent) }
                                else { selectedAgents.remove(agent) }
                            }
                        ))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Adopt & Sync") {
                    isAdopting = true
                    Task {
                        await registryStore.adopt(installation, syncTo: Array(selectedAgents))
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAdopting)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Per-agent origin + enabled chips for the detail header.
private struct FlowChips: View {
    let installations: [SkillInstallation]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(installations) { installation in
                HStack(spacing: 4) {
                    Image(systemName: installation.agent.symbol)
                    Text(installation.origin.label)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(installation.isEnabled ? "On" : "Off")
                        .foregroundStyle(installation.isEnabled ? .green : .secondary)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
            }
        }
    }
}
