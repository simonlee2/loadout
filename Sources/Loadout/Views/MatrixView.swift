import SwiftUI

/// Center column: the inventory matrix. One row per skill slug, one column per
/// active agent showing that agent's state, plus a Skill column and Origin chip.
struct MatrixView: View {
    let rows: [SkillRow]
    let agents: [AgentID]
    @Binding var selection: SkillRow.ID?

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
            .width(min: 220, ideal: 300)

            TableColumnForEach(agents) { agent in
                TableColumn(agent.displayName) { (row: SkillRow) in
                    AgentStateCell(installation: row.installation(for: agent))
                }
                .width(min: 64, ideal: 84)
            }

            TableColumn("Origin") { row in
                OriginCell(row: row)
            }
            .width(min: 120, ideal: 180)
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

/// A single agent's state for a row: on / off / absent.
struct AgentStateCell: View {
    let installation: SkillInstallation?

    var body: some View {
        if let installation {
            if installation.isEnabled {
                Label("On", systemImage: "circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.stateCell)
            } else {
                Label("Off", systemImage: "slash.circle")
                    .foregroundStyle(.secondary)
                    .labelStyle(.stateCell)
            }
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
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

/// Compact icon+text label style for the tight agent state columns.
private struct StateCellLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .imageScale(.small)
            configuration.title
                .font(.caption)
        }
    }
}

private extension LabelStyle where Self == StateCellLabelStyle {
    static var stateCell: StateCellLabelStyle { StateCellLabelStyle() }
}
