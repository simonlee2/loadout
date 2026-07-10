import SwiftUI
import AppKit

@main
struct LoadoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var store: InventoryStore
    @State private var registryStore: RegistryStore
    @State private var watcher: DirectoryWatcher?

    init() {
        // One journal shared by config writes and registry installs, so the
        // History window sees everything.
        let journal = ChangeJournal()
        _store = State(initialValue: LoadoutApp.makeStore(journal: journal))
        _registryStore = State(initialValue: LoadoutApp.makeRegistryStore(journal: journal))
    }

    var body: some Scene {
        WindowGroup("Loadout") {
            ContentView(store: store, registryStore: registryStore)
                .task { startWatching() }
        }
        .defaultSize(width: 1100, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .sidebar) {
                HistoryCommand()
            }
        }

        Window("History", id: "history") {
            HistoryView(store: store)
        }
        .defaultSize(width: 480, height: 560)
    }

    private static func makeStore(journal: ChangeJournal) -> InventoryStore {
        let store = InventoryStore(scanners: makeScanners())
        // Sample mode stays read-only: its fixture installations carry fake
        // paths, and real writers would journal them into real configs.
        if ProcessInfo.processInfo.environment["LOADOUT_SAMPLE"] == nil {
            store.configureWriting(
                writers: [ClaudeCodeConfigWriter(), CodexConfigWriter()],
                journal: journal
            )
        }
        return store
    }

    private static func makeRegistryStore(journal: ChangeJournal) -> RegistryStore {
        // Sample mode browses fixtures and installs in-memory only.
        if ProcessInfo.processInfo.environment["LOADOUT_SAMPLE"] != nil {
            return RegistryStore(
                adapters: [PreviewRegistryAdapter()],
                library: PreviewLibrary(),
                journal: journal
            )
        }
        // WellKnownAdapter (the /.well-known/skills convention) stays unwired
        // until a real site serves an index — add per-site instances here.
        return RegistryStore(
            adapters: [SkillsShAdapter(), ClawHubAdapter()],
            library: SkillLibrary(),
            journal: journal
        )
    }

    private static func makeScanners() -> [any AgentScanner] {
        // Debug harness: `LOADOUT_SAMPLE=1 swift run Loadout` swaps in the
        // SampleScanner fixtures (disabled + multi-agent rows) instead of the
        // real read-only scanners.
        if ProcessInfo.processInfo.environment["LOADOUT_SAMPLE"] != nil {
            return [
                SampleScanner(agent: .claudeCode),
                SampleScanner(agent: .codex),
            ]
        }
        return [
            ClaudeCodeScanner(),
            CodexScanner(),
        ]
    }

    /// Rescans when anything under the agents' skill or config paths changes.
    /// Watches specific subpaths rather than whole agent roots — `~/.claude`
    /// and `~/.codex` also hold session logs that churn constantly.
    private func startWatching() {
        guard watcher == nil else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let store = store
        let watcher = DirectoryWatcher(paths: [
            "\(home)/.claude/skills",
            "\(home)/.claude/plugins",
            "\(home)/.claude/settings.json",
            "\(home)/.codex/skills",
            "\(home)/.codex/config.toml",
        ]) {
            Task { await store.rescan() }
        }
        watcher.start()
        self.watcher = watcher
    }
}

/// Menu command that opens the auxiliary History window (⌘Y). Kept as its own
/// view so it can read `openWindow` from the environment.
private struct HistoryCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("History") {
            openWindow(id: "history")
        }
        .keyboardShortcut("y", modifiers: .command)
    }
}

/// Makes the app behave like a regular Dock app when launched via `swift run`
/// (no app bundle), bringing the window to the front.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        scheduleSnapshotIfRequested()
    }

    /// Debug harness: `LOADOUT_SNAPSHOT=/path/out.png swift run Loadout`
    /// renders the window to a PNG once the first scan has settled, then
    /// quits. Self-rendering needs no Screen Recording permission, so
    /// automated sessions can capture real screenshots.
    private func scheduleSnapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["LOADOUT_SNAPSHOT"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            WindowSnapshot.capture(to: path)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
