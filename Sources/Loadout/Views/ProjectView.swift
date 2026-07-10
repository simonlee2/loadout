import SwiftUI
import AppKit

// MARK: - Content column

/// Content column shown when the sidebar selects a project: a header naming
/// the project plus a table of every skill Claude Code can see inside it,
/// with the project-effective enablement and where that decision came from.
/// `states` is owned by `ContentView` and recomputed after each toggle/rescan.
struct ProjectView: View {
    let project: ProjectRef
    let states: [ProjectSkillState]
    let store: InventoryStore
    /// The shared toolbar search text; filters by name/slug/description.
    let searchText: String
    @Binding var selection: ProjectSkillState.ID?

    private var visibleStates: [ProjectSkillState] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return states }
        return states.filter { state in
            let installation = state.installation
            if installation.slug.lowercased().contains(query) { return true }
            if installation.displayName.lowercased().contains(query) { return true }
            if let description = installation.metadata.description,
               description.lowercased().contains(query) {
                return true
            }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if visibleStates.isEmpty {
                LedgerEmptyState(
                    systemImage: "folder",
                    title: searchText.isEmpty ? "No skills" : "No results",
                    detail: searchText.isEmpty
                        ? "No skills are visible inside this project."
                        : "No skills match “\(searchText)”."
                )
            } else {
                ledger
            }
        }
        .background(Ledger.paper)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name)
                .font(.system(size: 18, weight: .semibold, design: .serif))
                .foregroundStyle(Ledger.ink)
            Text(project.path)
                .font(.callout)
                .foregroundStyle(Ledger.quiet)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Ledger

    private var ledger: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleStates) { state in
                    ProjectLedgerRow(
                        state: state,
                        project: project,
                        store: store,
                        originText: originLabel(state.installation.origin),
                        note: Self.sourceNote(for: state),
                        isSelected: selection == state.id,
                        onSelect: { selection = state.id }
                    )
                }
            }
            .frame(maxWidth: Ledger.Space.measure)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Ledger.Space.gutter)
            .padding(.top, Ledger.Space.top)
            .padding(.bottom, 12)
        }
        .background(Ledger.paper)
    }

    /// Origin chip text, collapsing a matching project origin to "This project".
    private func originLabel(_ origin: SkillOrigin) -> String {
        switch origin {
        case .user: "User"
        case .system: "System"
        case .plugin: "Plugin"
        case .project(let path): path == project.path ? "This project" : "Project"
        }
    }

    /// Short note explaining who decided the state, shown only when an
    /// override is in play (nil = default-enabled, nothing to explain).
    static func sourceNote(for state: ProjectSkillState) -> String? {
        guard let source = state.source else { return nil }
        switch (source, state.isEnabledInProject) {
        case (.projectLocal, false), (.projectShared, false):
            return "off in this project"
        case (.user, false):
            return "off in your settings"
        case (.projectLocal, true), (.projectShared, true):
            return "on here overrides your settings"
        case (.user, true):
            return nil
        }
    }
}

// MARK: - Ledger row

/// One project skill styled like the matrix ledger: name + quiet description on
/// the left, a quiet origin/note cluster, and the teal-tinted enablement switch.
/// The whole row is a selection target; the toggle stays independently live.
private struct ProjectLedgerRow: View {
    let state: ProjectSkillState
    let project: ProjectRef
    let store: InventoryStore
    let originText: String
    let note: String?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.installation.displayName)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(isSelected ? Ledger.accentInk : Ledger.ink)
                    .lineLimit(1)
                if let description = state.installation.metadata.description,
                   !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ledger.quiet)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(originText)
                    .font(.system(size: 11))
                    .foregroundStyle(Ledger.quieter)
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Ledger.quiet)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: 190, alignment: .trailing)

            ProjectSkillToggle(state: state, project: project, store: store)
        }
        .padding(.vertical, Ledger.Space.rowV)
        .padding(.horizontal, Ledger.Space.rowH)
        .background(rowBackground)
        .overlay(alignment: .bottom) {
            if !isSelected {
                Rectangle().fill(Ledger.lineSoft).frame(height: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 10)
                .fill(Ledger.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Ledger.accent.opacity(0.28), lineWidth: 1)
                )
        }
    }
}

// MARK: - Toggle

/// A `.switch` toggle bound to one skill's project-effective enablement,
/// written through `InventoryStore.setSkill(_:enabled:in:)`. Same optimistic
/// anti-bounce pattern as `SkillEnableToggle`: `pending` holds the desired
/// value while the write+rescan is in flight so the switch doesn't snap back.
struct ProjectSkillToggle: View {
    let state: ProjectSkillState
    let project: ProjectRef
    let store: InventoryStore

    /// Optimistic value while a write is in flight; nil means "trust the state".
    @State private var pending: Bool?

    private var isOn: Bool { pending ?? state.isEnabledInProject }

    var body: some View {
        Toggle("Enabled", isOn: binding)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Ledger.accent)
            .disabled(store.isScanning)
            .help("Enable or disable \(state.installation.displayName) in \(project.name)")
            .onChange(of: state.isEnabledInProject) { pending = nil }
    }

    private var binding: Binding<Bool> {
        Binding<Bool>(
            get: { isOn },
            set: { newValue in
                pending = newValue
                let slug = state.installation.slug
                Task {
                    await store.setSkill(slug, enabled: newValue, in: project)
                    pending = nil
                }
            }
        )
    }
}

// MARK: - Detail column

/// Detail column for a project selection. Reuses the matrix `DetailView` when
/// the selected installation is one the inventory scan also produced;
/// otherwise falls back to a compact read-only detail.
struct ProjectDetailColumn: View {
    let state: ProjectSkillState?
    let store: InventoryStore
    let registryStore: RegistryStore

    /// The matrix row containing this exact installation, if the scan saw it.
    private var matrixRow: SkillRow? {
        guard let state else { return nil }
        return store.rows.first { row in
            row.installations.contains { $0.id == state.installation.id }
        }
    }

    var body: some View {
        if let state {
            if let row = matrixRow {
                DetailView(row: row, store: store, registryStore: registryStore)
            } else {
                CompactSkillDetail(installation: state.installation)
                    .id(state.id)
            }
        } else {
            LedgerEmptyState(
                systemImage: "sidebar.right",
                title: "Nothing selected",
                detail: "Select a skill from the project."
            )
        }
    }
}

/// Minimal read-only detail for an installation with no matrix row: name,
/// the SKILL.md body, and the on-disk location.
private struct CompactSkillDetail: View {
    let installation: SkillInstallation

    private enum DocumentState {
        case loading
        case loaded(SkillDocument)
    }

    @State private var document: DocumentState = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(installation.displayName)
                        .font(.title2.weight(.semibold))
                    Text(installation.slug)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    OriginChip(text: installation.origin.label)
                }

                Divider()

                bodySection
                pathSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(installation.displayName)
        .task(id: installation.id) {
            document = .loading
            document = .loaded(await SkillDocumentLoader.load(directory: installation.directory))
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SKILL.md")
                .font(.headline)

            switch document {
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .loaded(.missing):
                Label("SKILL.md could not be read.", systemImage: "doc.questionmark")
                    .foregroundStyle(.secondary)
            case .loaded(.blocks(let blocks)):
                SkillDocView(blocks: blocks)
            case .loaded(.plain(let raw)):
                Text(raw)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Location")
                .font(.headline)
            Text(installation.directory.path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([installation.directory])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
    }
}
