import SwiftUI
import AppKit

/// Right column: everything about the selected skill row. Reads the SKILL.md
/// file for the chosen installation at display time (read-only).
struct DetailView: View {
    let row: SkillRow?

    var body: some View {
        if let row {
            SkillDetailView(row: row)
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

    @State private var selectedAgent: AgentID?
    @State private var document: DocumentState = .loading

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
