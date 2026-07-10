import SwiftUI

/// Auxiliary window: the change journal, newest first. Each row can be reverted
/// (with confirmation) until it already has been. Shares the main window's
/// `InventoryStore` so reverting rescans the same inventory.
struct HistoryView: View {
    let store: InventoryStore

    @State private var confirmingRevert: ConfigChange?

    /// Journal entries newest-first (the journal appends newest last).
    private var entries: [ConfigChange] {
        (store.journal?.entries ?? []).reversed()
    }

    var body: some View {
        Group {
            if store.journal == nil {
                ContentUnavailableView {
                    Label("History Unavailable", systemImage: "clock.badge.xmark")
                } description: {
                    Text("Writing isn't configured yet, so Loadout has no change history to show.")
                }
            } else if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Changes Yet", systemImage: "clock")
                } description: {
                    Text("Loadout hasn't written anything.")
                }
            } else {
                List {
                    ForEach(entries) { entry in
                        HistoryRow(entry: entry) { confirmingRevert = entry }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Ledger.paper)
        .navigationTitle("History")
        .frame(minWidth: 360, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Text(countLabel)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Revert this change?",
            isPresented: Binding(
                get: { confirmingRevert != nil },
                set: { if !$0 { confirmingRevert = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmingRevert
        ) { entry in
            Button("Revert", role: .destructive) {
                Task { await store.revert(entry) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(entry.summary)
        }
    }

    private var countLabel: String {
        let count = entries.count
        return "\(count) \(count == 1 ? "change" : "changes")"
    }
}

/// One journaled change: kind icon, summary, agent badge, relative date, and a
/// revert affordance (or a "Reverted" chip once it has been undone).
private struct HistoryRow: View {
    let entry: ConfigChange
    let onRevert: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kindSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.summary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Label(entry.agent.displayName, systemImage: entry.agent.symbol)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())

                    Text(entry.date.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if entry.isReverted {
                Text("Reverted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            } else {
                Button("Revert", action: onRevert)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var kindSymbol: String {
        switch entry.kind {
        case .fileEdit: "doc.text"
        case .directoryMove: "shippingbox"
        case .pathAdd: "plus.square.on.square"
        }
    }
}
