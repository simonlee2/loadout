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
            LedgerEmptyState(title: "Loading skills…") {
                ProgressView()
                    .controlSize(.small)
            }
        } else if let error = state.error, state.skills.isEmpty {
            LedgerEmptyState(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't load this registry",
                detail: error
            ) {
                Button("Retry") {
                    Task { await loadContent(force: true) }
                }
            }
        } else if state.skills.isEmpty {
            LedgerEmptyState(
                systemImage: "shippingbox",
                title: searchText.isEmpty ? "No featured skills" : "No results",
                detail: searchText.isEmpty
                    ? "This registry has nothing to show yet."
                    : "No skills match “\(searchText)”."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.skills) { skill in
                        RegistrySkillRow(
                            skill: skill,
                            store: store,
                            isSelected: selection == skill.id,
                            onSelect: { selection = skill.id }
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
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(isSelected ? Ledger.accentInk : Ledger.ink)
                        .lineLimit(1)
                    if skill.slug != skill.name {
                        Text(skill.slug)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Ledger.quieter)
                            .lineLimit(1)
                    }
                }

                if let summary = skill.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ledger.quiet)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack(spacing: 10) {
                    if let count = skill.installCount {
                        Text(RegistryFormat.installs(count))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Ledger.quieter)
                    }
                    if let version = skill.version {
                        Text(version)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Ledger.quieter)
                    }
                    AuditWord(status: skill.audit)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RegistryInstallControl(skill: skill, store: store)
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
            LedgerEmptyState(
                systemImage: "sidebar.right",
                title: "Nothing selected",
                detail: "Select a skill from the registry."
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
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .foregroundStyle(Ledger.ink)
                    if skill.slug != skill.name {
                        Text(skill.slug)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        RegistryChip(text: skill.registry, symbol: "shippingbox")
                        if let version = skill.version {
                            RegistryChip(text: version)
                        }
                        AuditWord(status: skill.audit)
                    }
                    RegistryInstallControl(skill: skill, store: store, prominent: true)
                        .padding(.top, 4)
                }

                Divider()

                if let summary = skill.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary").font(Ledger.serifHeading(15)).foregroundStyle(Ledger.ink)
                        Text(summary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Details").font(Ledger.serifHeading(15)).foregroundStyle(Ledger.ink)
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
                        Text("Source").font(Ledger.serifHeading(15)).foregroundStyle(Ledger.ink)
                        Link(destination: url) {
                            Label(url.absoluteString, systemImage: "link")
                                .foregroundStyle(Ledger.accent)
                        }
                        .tint(Ledger.accent)
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
    /// Detail pane wants the teal prominent button; rows stay quietly bordered.
    var prominent = false

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
        } else if prominent {
            Button("Install…") { showingPopover = true }
                .buttonStyle(.borderedProminent)
                .tint(Ledger.accent)
                .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                    popover
                }
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

/// Audit result as a quiet ledger status word — sage "passed" / orange
/// "flagged", no capsule fill; hidden when unknown or absent.
struct AuditWord: View {
    let status: AuditStatus?

    var body: some View {
        switch status {
        case .passed:
            word("passed", tint: Ledger.sage)
        case .flagged:
            word("flagged", tint: Ledger.orange)
        case .unknown, nil:
            EmptyView()
        }
    }

    private func word(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.7)
            .foregroundStyle(tint)
            .lineLimit(1)
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
