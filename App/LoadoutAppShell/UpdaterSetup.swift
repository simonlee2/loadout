import SwiftUI
import Sparkle
import LoadoutKit

// MARK: - Sparkle wiring (app shell only)
//
// LoadoutKit is deliberately Sparkle-free so `swift test` / `swift run Loadout`
// never resolve Sparkle. All updater code lives here in the signed `.app`
// shell. `installSparkleUpdater()` (called from main.swift BEFORE
// `LoadoutApp.main()`) creates the standard Sparkle controller and hands
// LoadoutKit a closure that injects the "Check for Updates…" menu item via the
// public `LoadoutApp.appInfoCommands` hook.

/// Retains the updater controller for the whole app lifetime. `LoadoutApp.main()`
/// never returns, so a top-level `let` in main.swift would also work — but a
/// dedicated global keeps the intent explicit and the setup testable/reusable.
// Assigned once from `installSparkleUpdater()` on the main thread before the app
// starts, then only read. `nonisolated(unsafe)` satisfies Swift 6's global-state
// checking; the single-writer-before-launch access pattern makes it safe.
nonisolated(unsafe) private var sharedUpdaterController: SPUStandardUpdaterController?

/// Installs the Sparkle updater and registers the "Check for Updates…" menu
/// command. Call once, before `LoadoutApp.main()`.
func installSparkleUpdater() {
    // `startingUpdater: true` begins the automatic background update schedule
    // immediately. No delegates needed for the standard flow.
    let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    sharedUpdaterController = controller

    // Inject the menu item into LoadoutApp's command tree (placed after the
    // "About Loadout" item via CommandGroup(after: .appInfo) in LoadoutKit).
    LoadoutApp.appInfoCommands = {
        AnyView(CheckForUpdatesView(updater: controller.updater))
    }
}

/// Observes `SPUUpdater.canCheckForUpdates` so the menu item disables itself
/// while an update check is already in flight (the pattern from Sparkle's
/// SwiftUI documentation).
@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Check for Updates…" menu command.
private struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
