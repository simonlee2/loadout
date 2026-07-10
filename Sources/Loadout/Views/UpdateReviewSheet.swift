import SwiftUI

/// Review-and-apply sheet for a pending skill update. On open it stages the
/// update (downloads it into a temp dir and diffs it against the library copy),
/// shows a per-file change list with expandable unified diffs, and applies or
/// discards on the user's choice.
///
/// The staged update is transient: this view owns it and guarantees the temp
/// directory is discarded on Cancel and on any dismissal that isn't an Apply
/// (via the `onDisappear` guard), so nothing is ever left staged on disk.
struct UpdateReviewSheet: View {
    let slug: String
    /// The currently-installed version, for the "old → new" header. nil when the
    /// lock entry can't be found (shouldn't happen for a real update badge).
    let oldVersion: String?
    let registryStore: RegistryStore
    /// Snapshot harness only: a ready-made staged update to show without going
    /// through the store. Lets the offscreen capture render real diff content
    /// (the normal flow leaves this nil and stages via `registryStore`).
    var prestaged: StagedUpdate?

    @Environment(\.dismiss) private var dismiss

    @State private var staged: StagedUpdate?
    @State private var isStaging = true
    @State private var isApplying = false
    /// Set once the update is applied (or apply is attempted) so the dismissal
    /// guard doesn't discard a tree the library now owns.
    @State private var applied = false
    /// Guards against discarding twice (explicit Cancel + onDisappear).
    @State private var discarded = false

    var body: some View {
        VStack(spacing: 0) {
            if let staged {
                content(staged)
            } else {
                staging
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(Ledger.paper)
        .task { await stage() }
        .onDisappear { discardIfNeeded() }
    }

    // MARK: Staging

    private var staging: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing update…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func stage() async {
        // Only stage once; a re-entered task shouldn't re-download.
        guard staged == nil, isStaging else { return }
        if let prestaged {
            staged = prestaged
            isStaging = false
            return
        }
        let result = await registryStore.stageUpdate(slug: slug)
        isStaging = false
        if let result {
            staged = result
        } else {
            // Staging failed; the store surfaced the error via its alert.
            dismiss()
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ staged: StagedUpdate) -> some View {
        header(staged)
        Divider()
        List {
            ForEach(staged.changes) { change in
                FileChangeRow(change: change, startExpanded: prestaged != nil)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        Divider()
        footer(staged)
    }

    private func header(_ staged: StagedUpdate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(staged.slug) — \(RowStatus.shortVersion(oldVersion ?? "?")) → \(RowStatus.shortVersion(staged.newVersion))")
                .font(.system(size: 18, weight: .semibold, design: .serif))
                .foregroundStyle(Ledger.ink)
            Text(Self.summaryLine(staged.changes))
                .font(.callout)
                .foregroundStyle(Ledger.quiet)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private func footer(_ staged: StagedUpdate) -> some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) {
                discardIfNeeded()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Apply Update") {
                isApplying = true
                Task {
                    // The library takes ownership of the staged tree on apply.
                    applied = true
                    await registryStore.applyUpdate(staged)
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isApplying)
        }
        .padding(20)
    }

    // MARK: Lifecycle

    private func discardIfNeeded() {
        guard !applied, !discarded, let staged else { return }
        discarded = true
        registryStore.discardUpdate(staged)
    }

    // MARK: Copy

    /// e.g. "3 files changed: 1 added, 1 modified, 1 removed".
    static func summaryLine(_ changes: [FileChange]) -> String {
        let added = changes.filter { $0.kind == .added }.count
        let modified = changes.filter { $0.kind == .modified }.count
        let removed = changes.filter { $0.kind == .removed }.count
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added") }
        if modified > 0 { parts.append("\(modified) modified") }
        if removed > 0 { parts.append("\(removed) removed") }
        let noun = changes.count == 1 ? "file" : "files"
        let detail = parts.isEmpty ? "" : ": \(parts.joined(separator: ", "))"
        return "\(changes.count) \(noun) changed\(detail)"
    }
}

/// One row in the change list: an icon + relative path, with an expandable
/// unified diff when the change carries preview lines.
private struct FileChangeRow: View {
    let change: FileChange
    /// Snapshot harness pre-expands diffs so the offscreen capture shows them.
    var startExpanded = false
    @State private var expanded: Bool

    init(change: FileChange, startExpanded: Bool = false) {
        self.change = change
        self.startExpanded = startExpanded
        _expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        if change.diff.isEmpty {
            HStack {
                label
                Spacer()
                Text("Binary or large file")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                DiffView(lines: change.diff)
                    .padding(.top, 4)
            } label: {
                label
            }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: change.kind.symbol)
                .foregroundStyle(change.kind.tint)
            Text(change.relativePath)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Renders unified-diff-style lines ("+ …" / "- …" / "  …") in a monospaced
/// block with per-line color and a subtle per-line background tint.
private struct DiffView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(foreground(for: line))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(background(for: line))
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary)
        )
        .textSelection(.enabled)
    }

    private func foreground(for line: String) -> Color {
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return .secondary
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+") { return .green.opacity(0.12) }
        if line.hasPrefix("-") { return .red.opacity(0.12) }
        return .clear
    }
}

private extension FileChange.Kind {
    var symbol: String {
        switch self {
        case .added: return "plus.circle"
        case .removed: return "minus.circle"
        case .modified: return "pencil.circle"
        }
    }

    var tint: Color {
        switch self {
        case .added: return .green
        case .removed: return .red
        case .modified: return .orange
        }
    }
}
