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
        [
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
            if let window = NSApp.windows.first(where: { $0.isVisible }),
               let view = window.contentView?.superview ?? window.contentView,
               let data = Self.renderLayerTree(of: view, scale: window.backingScaleFactor) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    /// Renders the view's CoreAnimation layer tree to PNG. Unlike
    /// `cacheDisplay`, this includes SwiftUI's layer-hosted subtrees (e.g.
    /// the sidebar); backdrop/material layers render transparent, so the
    /// context is pre-filled with the window background.
    private static func renderLayerTree(of view: NSView, scale: CGFloat) -> Data? {
        guard let layer = view.layer else { return nil }
        let size = view.bounds.size
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              )
        else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        // Backdrop (material) layers render opaque white offscreen and would
        // paint over their siblings; hide them for the duration of the render.
        let hidden = hideBackdropLayers(in: layer)
        layer.render(in: context)
        hidden.forEach { $0.isHidden = false }

        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private static func hideBackdropLayers(in layer: CALayer) -> [CALayer] {
        var hidden: [CALayer] = []
        if String(describing: type(of: layer)).contains("Backdrop"), !layer.isHidden {
            layer.isHidden = true
            hidden.append(layer)
        }
        for sublayer in layer.sublayers ?? [] {
            hidden.append(contentsOf: hideBackdropLayers(in: sublayer))
        }
        return hidden
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
