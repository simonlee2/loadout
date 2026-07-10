import SwiftUI

/// Center column: the inventory matrix. One row per skill slug, one column per
/// active agent showing that agent's state, plus a Skill column and Origin chip.
struct MatrixView: View {
    let rows: [SkillRow]
    let agents: [AgentID]
    let store: InventoryStore
    let lockVersions: [String: String]
    let updatesAvailable: [String: String]
    let statusCache: RowStatusCache
    @Binding var selection: SkillRow.ID?

    private func status(for row: SkillRow) -> RowStatus {
        RowStatus.compute(
            row,
            lockVersions: lockVersions,
            updatesAvailable: updatesAvailable,
            cache: statusCache
        )
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Skills",
                    systemImage: "square.grid.2x2",
                    description: Text("Nothing matches the current filter or search.")
                )
            } else {
                table
            }
        }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Skill") { row in
                SkillCell(row: row)
            }
            .width(min: 190, ideal: 220)

            TableColumnForEach(agents) { agent in
                TableColumn(agent.displayName) { (row: SkillRow) in
                    AgentStateCell(installation: row.installation(for: agent), store: store)
                }
                .width(min: 64, ideal: 84)
            }

            TableColumn("Origin") { row in
                OriginCell(row: row)
            }
            .width(min: 110, ideal: 130)

            TableColumn("Status") { row in
                StatusCell(status: status(for: row))
            }
            .width(min: 100, ideal: 120)
        }
    }
}

/// Skill name + a dimmed one-line description.
private struct SkillCell: View {
    let row: SkillRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.displayName)
                .lineLimit(1)
            if let summary = row.summary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A single agent's state for a row: a live switch, a disabled switch (with a
/// reason), or a faint dash when the skill is absent for that agent.
struct AgentStateCell: View {
    let installation: SkillInstallation?
    let store: InventoryStore

    var body: some View {
        if let installation {
            SkillEnableToggle(installation: installation, store: store)
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }
}

/// A `.switch` toggle bound to one installation's enabled state, driven through
/// the store. Handles plugin-scope confirmation, optimistic local state so the
/// switch doesn't bounce during the write+rescan, and a disabled/greyed state
/// (with an explanatory `.help`) when the agent can't toggle this skill.
struct SkillEnableToggle: View {
    let installation: SkillInstallation
    let store: InventoryStore
    /// Detail pane wants a visible "Enabled/Disabled" label; the matrix hides it.
    var showsLabel = false

    /// Optimistic value while a write is in flight; nil means "trust the store".
    @State private var pending: Bool?
    @State private var confirmingPlugin = false
    @State private var desiredValue = false

    private var isOn: Bool { pending ?? installation.isEnabled }
    private var canToggle: Bool { store.canToggle(installation) }

    var body: some View {
        toggle
            .toggleStyle(.switch)
            .controlSize(showsLabel ? .small : .mini)
            .disabled(!canToggle || store.isScanning)
            .help(helpText)
            .onChange(of: installation.isEnabled) { pending = nil }
            .confirmationDialog(
                confirmTitle,
                isPresented: $confirmingPlugin,
                titleVisibility: .visible
            ) {
                Button(desiredValue ? "Turn On" : "Turn Off") {
                    let value = desiredValue
                    Task {
                        await store.setEnabled(value, for: installation)
                        pending = nil
                    }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text(confirmMessage)
            }
    }

    private var binding: Binding<Bool> {
        Binding<Bool>(get: { isOn }, set: { handleChange($0) })
    }

    @ViewBuilder private var toggle: some View {
        if showsLabel {
            Toggle(isOn ? "Enabled" : "Disabled", isOn: binding)
        } else {
            Toggle("Enabled", isOn: binding)
                .labelsHidden()
        }
    }

    private func handleChange(_ newValue: Bool) {
        if case .plugin = store.toggleScope(installation) {
            desiredValue = newValue
            pending = newValue
            confirmingPlugin = true
        } else {
            pending = newValue
            Task {
                await store.setEnabled(newValue, for: installation)
                pending = nil
            }
        }
    }

    // MARK: Copy

    private var helpText: String {
        canToggle
            ? "Enable or disable \(installation.displayName) for \(installation.agent.displayName)"
            : Self.disabledReason(installation)
    }

    private var pluginName: String {
        if case .plugin(let name) = store.toggleScope(installation) { return name }
        return ""
    }

    private var confirmTitle: String {
        "\(desiredValue ? "Turn on" : "Turn off") plugin \"\(pluginName)\"?"
    }

    private var confirmMessage: String {
        let count = store.siblings(of: installation).count
        let verb = desiredValue ? "enables" : "disables"
        let noun = count == 1 ? "skill" : "skills"
        return "This \(verb) its \(count) \(noun) for \(installation.agent.displayName)."
    }

    static func disabledReason(_ installation: SkillInstallation) -> String {
        let agent = installation.agent.displayName
        switch installation.origin {
        case .project:
            return "\(agent) has no per-skill switch for project skills yet."
        case .system:
            return "\(agent) has no per-skill switch for system skills yet."
        case .user, .plugin:
            return "\(agent) can't toggle this skill yet."
        }
    }
}

/// Distinct origin labels for the row, rendered as chips.
private struct OriginCell: View {
    let row: SkillRow

    private var labels: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for installation in row.installations {
            let label = installation.origin.label
            if seen.insert(label).inserted {
                result.append(label)
            }
        }
        return result
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(labels, id: \.self) { label in
                OriginChip(text: label)
            }
        }
    }
}

/// Small pill styling reused in the matrix and detail header.
struct OriginChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

