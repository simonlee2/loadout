import SwiftUI
import AppKit
import os

/// Root three-column layout: sidebar filter, inventory matrix, and detail.
struct ContentView: View {
    let store: InventoryStore
    let registryStore: RegistryStore

    @Environment(\.openWindow) private var openWindow
    @State private var sidebarSelection: SidebarSelection = .allSkills
    @State private var selectedRowID: SkillRow.ID?
    @State private var selectedRegistrySkillID: RegistrySkill.ID?
    @State private var selectedProjectSkillID: ProjectSkillState.ID?
    /// Skill states for the selected project. `projectSkillStates(in:)` is a
    /// function call (not cached in the store), so the result is held here and
    /// recomputed via `.task(id:)` whenever the project or scan date changes.
    @State private var projectSkillStates: [ProjectSkillState] = []
    @State private var searchText = ""
    @State private var statusCache = RowStatusCache()
    // Snapshot harness only: the update review sheet is a separate NSWindow that
    // WindowSnapshot's layer-tree capture can't reach, so LOADOUT_SNAPSHOT_UPDATE
    // presents the sheet's content as an inline overlay for the capture instead.
    @State private var snapshotUpdateSlug: String?
    // Snapshot/autodrive harnesses: vibrant sidebar content can't render
    // offscreen, so captures collapse it rather than show a blank column.
    @State private var columnVisibility: NavigationSplitViewVisibility =
        (ProcessInfo.processInfo.environment["LOADOUT_SNAPSHOT"] != nil
            || ProcessInfo.processInfo.environment["LOADOUT_AUTODRIVE"] != nil)
            ? .doubleColumn : .all

    /// Rows after applying the sidebar filter and the search field.
    private var visibleRows: [SkillRow] {
        store.rows.filter { matchesSidebar($0) && matchesSearch($0) }
    }

    /// slug → managed version, from the library's lockfile.
    private var lockVersions: [String: String] {
        Dictionary(registryStore.lockEntries.map { ($0.slug, $0.version) }) { first, _ in first }
    }

    /// Rows flagged for the "Needs Attention" smart list (update / differs /
    /// dangling symlink). Count feeds the sidebar badge; also used to filter.
    private var needsAttentionRows: [SkillRow] {
        store.rows.filter {
            RowStatus.needsAttention(
                $0,
                lockVersions: lockVersions,
                updatesAvailable: registryStore.updatesAvailable,
                cache: statusCache
            )
        }
    }

    private var selectedRow: SkillRow? {
        guard let selectedRowID else { return nil }
        return store.rows.first { $0.id == selectedRowID }
    }

    /// The registry id when the sidebar has a registry selected, else nil.
    private var selectedRegistryID: String? {
        if case .registry(let id) = sidebarSelection { return id }
        return nil
    }

    private func selectedRegistrySkill(in registryID: String) -> RegistrySkill? {
        guard let selectedRegistrySkillID else { return nil }
        return registryStore.browse[registryID]?.skills.first { $0.id == selectedRegistrySkillID }
    }

    /// The project when the sidebar has one selected, else nil.
    private var selectedProject: ProjectRef? {
        if case .project(let path) = sidebarSelection {
            return store.projects.first { $0.path == path }
        }
        return nil
    }

    private var selectedProjectSkillState: ProjectSkillState? {
        guard let selectedProjectSkillID else { return nil }
        return projectSkillStates.first { $0.id == selectedProjectSkillID }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                store: store,
                registryStore: registryStore,
                needsAttentionCount: needsAttentionRows.count,
                selection: $sidebarSelection
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } content: {
            Group {
                if let registryID = selectedRegistryID {
                    RegistryBrowserView(
                        registryID: registryID,
                        store: registryStore,
                        searchText: searchText,
                        selection: $selectedRegistrySkillID
                    )
                } else if let project = selectedProject {
                    ProjectView(
                        project: project,
                        states: projectSkillStates,
                        store: store,
                        searchText: searchText,
                        selection: $selectedProjectSkillID
                    )
                } else {
                    VStack(spacing: 0) {
                        MatrixView(
                            rows: visibleRows,
                            agents: store.activeAgents,
                            store: store,
                            lockVersions: lockVersions,
                            updatesAvailable: registryStore.updatesAvailable,
                            statusCache: statusCache,
                            selection: $selectedRowID
                        )
                        Divider()
                        StatusBarView(store: store)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 620)
            .navigationTitle("Loadout")
        } detail: {
            Group {
                if let registryID = selectedRegistryID {
                    RegistryDetailView(
                        skill: selectedRegistrySkill(in: registryID),
                        store: registryStore
                    )
                } else if selectedProject != nil {
                    ProjectDetailColumn(
                        state: selectedProjectSkillState,
                        store: store,
                        registryStore: registryStore
                    )
                } else {
                    DetailView(row: selectedRow, store: store, registryStore: registryStore)
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 400)
        }
        .overlay {
            if let slug = snapshotUpdateSlug {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    UpdateReviewSheet(
                        slug: slug,
                        oldVersion: lockVersions[slug],
                        registryStore: registryStore,
                        prestaged: PreviewLibrary.sampleStagedUpdate(
                            slug: slug,
                            newVersion: registryStore.updatesAvailable[slug] ?? "2.1.0"
                        )
                    )
                    .frame(width: 620, height: 520)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 24)
                }
            }
        }
        .onChange(of: sidebarSelection) {
            selectedRegistrySkillID = nil
            selectedProjectSkillID = nil
        }
        // Recompute the project's skill states whenever the selected project
        // or the scan date changes (each toggle ends in a rescan).
        .task(id: ProjectStatesKey(path: selectedProject?.path, scan: store.lastScan)) {
            if let selectedProject {
                projectSkillStates = store.projectSkillStates(in: selectedProject)
            } else {
                projectSkillStates = []
            }
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: searchPrompt
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.rescan() }
                } label: {
                    if store.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.isScanning)
                .help("Rescan for installed skills")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await registryStore.checkForUpdates() }
                } label: {
                    if registryStore.isCheckingUpdates {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(registryStore.isCheckingUpdates)
                .help("Check for updates")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    openWindow(id: "history")
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .help("Show the change history")
            }
        }
        .alert(
            "Action Failed",
            isPresented: Binding(
                get: { store.lastActionError != nil },
                set: { presenting in if !presenting { store.lastActionError = nil } }
            ),
            presenting: store.lastActionError
        ) { _ in
            Button("OK", role: .cancel) { store.lastActionError = nil }
        } message: { error in
            Text(error)
        }
        .alert(
            "Action Failed",
            isPresented: Binding(
                get: { registryStore.lastActionError != nil },
                set: { presenting in if !presenting { registryStore.lastActionError = nil } }
            ),
            presenting: registryStore.lastActionError
        ) { _ in
            Button("OK", role: .cancel) { registryStore.lastActionError = nil }
        } message: { error in
            Text(error)
        }
        .task {
            store.refreshProjects()
            await store.rescan()
            // Kick off a non-blocking update check now that the first scan has
            // populated the inventory (badges/status fill in as it resolves).
            Task { await registryStore.checkForUpdates() }
            // Wake the personal collection (checks entitlement + iCloud account).
            Task { await registryStore.activateCollection() }
            // Live-test harness: LOADOUT_COLLECTION_TEST=<slug> publishes that
            // skill to the collection, lists, downloads it back, verifies the
            // tree hash, logs the outcome, and quits. Only runs when signed.
            if let slug = ProcessInfo.processInfo.environment["LOADOUT_COLLECTION_TEST"] {
                await runCollectionTest(slug: slug)
            }
            // Snapshot harness: pre-select the first registry so the capture
            // shows the browser instead of the matrix.
            if ProcessInfo.processInfo.environment["LOADOUT_SNAPSHOT_REGISTRY"] != nil,
               let first = registryStore.adapters.first {
                sidebarSelection = .registry(id: first.id)
                await registryStore.loadFeatured(registry: first.id)
                selectedRegistrySkillID = registryStore.browse[first.id]?.skills.first?.id
            }
            // Snapshot harness: select a row so the detail pane has content.
            if ProcessInfo.processInfo.environment["LOADOUT_SNAPSHOT"] != nil {
                selectedRowID = (visibleRows.first { $0.summary != nil } ?? visibleRows.first)?.id
            }
            // Snapshot harness: pre-select the first project.
            if ProcessInfo.processInfo.environment["LOADOUT_SNAPSHOT_PROJECT"] != nil,
               let first = store.projects.first {
                sidebarSelection = .project(path: first.path)
            }
            // Snapshot harness: stage + present the update review sheet for a
            // specific slug (as an inline overlay, see `snapshotUpdateSlug`).
            if let slug = ProcessInfo.processInfo.environment["LOADOUT_SNAPSHOT_UPDATE"] {
                await registryStore.checkForUpdates()
                sidebarSelection = .allSkills
                selectedRowID = store.rows.first { $0.slug == slug }?.id
                snapshotUpdateSlug = slug
            }
            // Autodrive harness: run the scripted end-to-end scenario.
            if let outDir = ProcessInfo.processInfo.environment["LOADOUT_AUTODRIVE"] {
                await runAutoDrive(outDir: outDir)
            }
        }
    }

    private var searchPrompt: String {
        if selectedRegistryID != nil { return "Search registry" }
        if selectedProject != nil { return "Search project skills" }
        return "Search skills"
    }

    // MARK: Collection live-test harness

    @MainActor
    private func runCollectionTest(slug: String) async {
        let log = Logger(subsystem: "com.simonlee.loadout", category: "collection-test")
        await registryStore.activateCollection()
        guard let collection = registryStore.collection else {
            log.error("COLLECTION-TEST no collection configured"); NSApp.terminate(nil); return
        }
        guard collection.isAvailable else {
            log.error("COLLECTION-TEST unavailable: \(collection.unavailabilityReason ?? "?", privacy: .public)")
            NSApp.terminate(nil); return
        }
        guard let installation = store.installations.first(where: { $0.slug == slug }) else {
            log.error("COLLECTION-TEST skill \(slug, privacy: .public) not found"); NSApp.terminate(nil); return
        }
        do {
            try await collection.publish(
                slug: slug,
                name: installation.displayName,
                summary: installation.metadata.description,
                directory: installation.directory
            )
            let skills = try await collection.list()
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("collection-test-\(slug)", isDirectory: true)
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let hash = try await collection.download(slug: slug, to: temp)
            let localHash = try TreeHash.hash(directory: installation.directory)
            let ok = hash == localHash
            log.notice("COLLECTION-TEST published=\(slug, privacy: .public) listed=\(skills.count) roundtrip=\(ok ? "HASH-OK" : "HASH-MISMATCH", privacy: .public)")
            try? FileManager.default.removeItem(at: temp)
        } catch {
            log.error("COLLECTION-TEST failed: \(error.localizedDescription, privacy: .public)")
        }
        NSApp.terminate(nil)
    }

    // MARK: Filtering

    private func matchesSidebar(_ row: SkillRow) -> Bool {
        switch sidebarSelection {
        case .allSkills:
            return true
        case .needsAttention:
            return RowStatus.needsAttention(
                row,
                lockVersions: lockVersions,
                updatesAvailable: registryStore.updatesAvailable,
                cache: statusCache
            )
        case .origin(let kind):
            return row.installations.contains { $0.origin.kind == kind }
        case .agent(let agent):
            return row.installation(for: agent) != nil
        case .registry, .project:
            // Registry/project selection swaps the content column entirely;
            // the matrix isn't shown, so nothing needs to match.
            return false
        }
    }

    private func matchesSearch(_ row: SkillRow) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let needle = query.lowercased()

        if row.slug.lowercased().contains(needle) { return true }
        if row.displayName.lowercased().contains(needle) { return true }
        if let summary = row.summary, summary.lowercased().contains(needle) { return true }

        return row.installations.contains { installation in
            if let name = installation.metadata.name, name.lowercased().contains(needle) {
                return true
            }
            if let description = installation.metadata.description,
               description.lowercased().contains(needle) {
                return true
            }
            return false
        }
    }

    // MARK: Autodrive harness

    /// Debug harness: `LOADOUT_AUTODRIVE=/path/outdir swift run Loadout` drives a
    /// scripted scenario over the real @State the controls bind to (exercising
    /// the actual filter/selection/render paths), capturing a PNG plus a
    /// `results.jsonl` line per step, then quits. Only reached when the env var
    /// is set; it never writes to any agent config or skill directory.
    @MainActor
    private func runAutoDrive(outDir: String) async {
        let base = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let resultsURL = base.appendingPathComponent("results.jsonl")
        // Start each run with a fresh results file.
        try? FileManager.default.removeItem(at: resultsURL)
        FileManager.default.createFile(atPath: resultsURL.path, contents: nil)

        func record(_ step: Int, _ name: String, expected: String, actual: String, pass: Bool) {
            let line = "{\"step\": \(step), \"name\": \"\(name)\", \"expected\": \(expected), \"actual\": \(actual), \"pass\": \(pass)}\n"
            guard let data = line.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: resultsURL) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
        func snapshot(_ file: String) {
            WindowSnapshot.capture(to: base.appendingPathComponent(file).path)
        }
        // Let SwiftUI apply state mutations and re-render before we read/capture.
        func settle() async { try? await Task.sleep(for: .milliseconds(800)) }

        // Step 1: baseline — all skills, no selection.
        sidebarSelection = .allSkills
        searchText = ""
        selectedRowID = nil
        await settle()
        let baseline = visibleRows.count
        record(1, "baseline all skills", expected: "26", actual: "\(baseline)", pass: baseline == 26)

        // Step 2: sidebar filter → agent Claude Code.
        sidebarSelection = .agent(.claudeCode)
        await settle()
        let claudeCount = visibleRows.count
        snapshot("step2-claudecode.png")
        record(2, "filter agent claudeCode", expected: "21", actual: "\(claudeCount)", pass: claudeCount == 21)

        // Step 3: sidebar filter → agent Codex.
        sidebarSelection = .agent(.codex)
        await settle()
        let codexCount = visibleRows.count
        snapshot("step3-codex.png")
        record(3, "filter agent codex", expected: "5", actual: "\(codexCount)", pass: codexCount == 5)

        // Step 4: sidebar filter → origin System.
        sidebarSelection = .origin(.system)
        await settle()
        let systemCount = visibleRows.count
        record(4, "filter origin system", expected: "5", actual: "\(systemCount)", pass: systemCount == 5)

        // Step 5: search "ios". Expected (slug-only) is the ios-* skill count.
        sidebarSelection = .allSkills
        searchText = "ios"
        await settle()
        let iosCount = visibleRows.count
        snapshot("step5-search-ios.png")
        record(5, "search ios", expected: "5", actual: "\(iosCount)", pass: iosCount == 5)

        // Step 6: clear search, select swiftui-patterns, verify DetailView loads.
        searchText = ""
        await settle()
        let target = store.rows.first { $0.slug == "swiftui-patterns" }
        selectedRowID = target?.id
        await settle()
        // Verify the SKILL.md read via the exact loader DetailView renders from.
        var loadStatus = "no-row"
        if let installation = target?.installations.first {
            loadStatus = (await SkillDocumentLoader.load(directory: installation.directory)).statusDescription
        }
        await settle() // let DetailView finish rendering the loaded document
        snapshot("step6-detail-swiftui-patterns.png")
        let detailOK = loadStatus == "attributed"
        record(6, "select swiftui-patterns detail load", expected: "\"attributed\"", actual: "\"\(loadStatus)\"", pass: detailOK)

        // Step 7: rescan — count stable, no scan errors.
        await store.rescan()
        sidebarSelection = .allSkills
        selectedRowID = nil
        await settle()
        let afterRescan = visibleRows.count
        let noErrors = store.scanErrors.isEmpty
        record(7, "rescan stable count and no errors", expected: "26", actual: "\(afterRescan)", pass: afterRescan == 26 && noErrors)

        // Step 8: final summary of core invariants.
        let coreOK = baseline == 26 && afterRescan == 26 && noErrors && detailOK
        let summary = "\"baseline=\(baseline) claude=\(claudeCount) codex=\(codexCount) system=\(systemCount) ios=\(iosCount) detail=\(loadStatus) afterRescan=\(afterRescan) errors=\(store.scanErrors.count)\""
        record(8, "final summary", expected: "\"26/21/5/5/attributed/no-errors\"", actual: summary, pass: coreOK)

        NSApp.terminate(nil)
    }
}

/// Composite `task(id:)` key so either switching projects or a completed
/// rescan re-derives the selected project's skill states.
private struct ProjectStatesKey: Hashable {
    let path: String?
    let scan: Date?
}
