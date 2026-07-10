import SwiftUI
import AppKit

@main
struct LoadoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var store = InventoryStore(scanners: LoadoutApp.makeScanners())
    @State private var watcher: DirectoryWatcher?

    var body: some Scene {
        WindowGroup("Loadout") {
            ContentView(store: store)
                .task { startWatching() }
        }
        .defaultSize(width: 1100, height: 700)
        .windowToolbarStyle(.unified)
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
