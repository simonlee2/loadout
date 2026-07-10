import SwiftUI

/// Center column: the inventory as a grouped paper ledger. Rows are bucketed
/// into "Your skills", "System", and "From registries", each with a serif
/// heading and count. One row per skill slug; the trailing cluster shows each
/// active agent's presence + anti-bounce toggle, then a quiet small-caps status
/// word. Selecting a row drives the detail column (unchanged behavior).
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

    /// Which ledger section a row belongs to. Priority: library-managed rows go
    /// to "From registries"; otherwise a user-scoped installation makes it a
    /// personal skill, a system one makes it System, and anything else (plugins,
    /// project-only) falls back to the personal shelf so no row is ever dropped.
    private enum Bucket: Int, CaseIterable {
        case user, system, registries

        var title: String {
            switch self {
            case .user: "Your skills"
            case .system: "System"
            case .registries: "From registries"
            }
        }
    }

    private func bucket(for row: SkillRow) -> Bucket {
        if lockVersions[row.slug] != nil { return .registries }
        let origins = Set(row.installations.map(\.origin.kind))
        if origins.contains(.user) { return .user }
        if origins.contains(.system) { return .system }
        if origins.contains(.plugin) { return .registries }
        return .user
    }

    private var grouped: [(bucket: Bucket, rows: [SkillRow])] {
        Bucket.allCases.compactMap { bucket in
            let matching = rows.filter { self.bucket(for: $0) == bucket }
            return matching.isEmpty ? nil : (bucket, matching)
        }
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                LedgerEmptyState(
                    systemImage: "square.grid.2x2",
                    title: "No skills",
                    detail: "Nothing matches the current filter or search."
                )
            } else {
                ledger
            }
        }
    }

    private var ledger: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(grouped.enumerated()), id: \.element.bucket) { index, group in
                    SectionHeader(
                        title: group.bucket.title,
                        count: group.rows.count,
                        isFirst: index == 0,
                        // The first header carries the column legend that caps
                        // the per-agent toggle columns below it.
                        legendAgents: index == 0 ? agents : []
                    )
                    ForEach(group.rows) { row in
                        LedgerRow(
                            row: row,
                            agents: agents,
                            store: store,
                            status: status(for: row),
                            isSelected: selection == row.id,
                            onSelect: { selection = row.id }
                        )
                    }
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
}

// MARK: - Section heading

/// Serif section heading with a trailing count — the editorial rhythm from the
/// mockup, without the old hairline rule or uppercase aside label. The first
/// header additionally right-aligns a quiet column legend naming the agent
/// toggle columns, so the per-agent switches below read as labeled columns.
private struct SectionHeader: View {
    let title: String
    let count: Int
    let isFirst: Bool
    var legendAgents: [AgentID] = []

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(Ledger.serifHeading())
                .foregroundStyle(Ledger.ink)
            Text("\(count)")
                .font(.system(size: 12.5))
                .foregroundStyle(Ledger.quieter)
                .monospacedDigit()
            Spacer(minLength: 8)

            if !legendAgents.isEmpty {
                Text(legendAgents.map(\.displayName).joined(separator: " · "))
                    .font(.system(size: 10.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(Ledger.quieter)
                    .lineLimit(1)
                    // Sit over the toggle cluster, not the status words: skip
                    // the status slot plus the row's inter-cluster spacing.
                    .padding(.trailing, 96 + 14)
            }
        }
        .padding(.horizontal, Ledger.Space.rowH)
        .padding(.bottom, 6)
        .padding(.top, isFirst ? 0 : Ledger.Space.beforeHeading)
        .padding(.bottom, Ledger.Space.afterHeading)
    }
}

// MARK: - Ledger row

/// One skill: name + one-line description on the left, per-agent presence +
/// toggle and a quiet status word on the right. The whole row is a selection
/// target; the toggles remain independently interactive.
private struct LedgerRow: View {
    let row: SkillRow
    let agents: [AgentID]
    let store: InventoryStore
    let status: RowStatus
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(isSelected ? Ledger.accentInk : Ledger.ink)
                    .lineLimit(1)
                if let summary = row.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ledger.quiet)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                ForEach(agents) { agent in
                    AgentPresenceCell(
                        installation: row.installation(for: agent),
                        agent: agent,
                        store: store
                    )
                }
            }

            LedgerStatusLabel(status: status)
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

/// One agent's presence for a row: its monogram plus the live anti-bounce
/// toggle, or the monogram beside a faint dash when the skill is absent for
/// that agent. Fixed width so clusters align down the ledger.
private struct AgentPresenceCell: View {
    let installation: SkillInstallation?
    let agent: AgentID
    let store: InventoryStore

    var body: some View {
        HStack(spacing: 5) {
            Text(agent.monogram)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(installation == nil ? Ledger.quieter.opacity(0.6) : Ledger.inkSoft)

            if let installation {
                SkillEnableToggle(installation: installation, store: store)
            } else {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(Ledger.quieter.opacity(0.6))
                    .frame(width: 26)
            }
        }
        .frame(width: 62, alignment: .trailing)
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
            .tint(Ledger.accent)
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
                .fixedSize()
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

/// Small pill styling reused in the detail header and project view. Kept on the
/// ledger palette so it reads as paper, not the old skin.
struct OriginChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .lineLimit(1)
            .foregroundStyle(Ledger.inkSoft)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Ledger.paper2, in: Capsule())
            .overlay(Capsule().strokeBorder(Ledger.line, lineWidth: 0.5))
    }
}
