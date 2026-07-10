import AppKit

/// Debug-harness helper that renders the app's live window to a PNG without
/// needing Screen Recording permission. Shared by the `LOADOUT_SNAPSHOT` and
/// `LOADOUT_AUTODRIVE` harnesses.
///
/// This is capture-only: it never mutates app state and is only reached when a
/// harness env var is set, so it does not affect normal read-only behavior.
enum WindowSnapshot {
    /// Renders the first visible window to `path` (PNG). Returns whether a file
    /// was written.
    @MainActor
    @discardableResult
    static func capture(to path: String) -> Bool {
        guard
            let window = NSApp.windows.first(where: { $0.isVisible }),
            let view = window.contentView?.superview ?? window.contentView,
            let data = renderLayerTree(of: view, scale: window.backingScaleFactor)
        else {
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    /// Renders the view's CoreAnimation layer tree to PNG. Unlike
    /// `cacheDisplay`, this includes SwiftUI's layer-hosted subtrees (e.g.
    /// the sidebar); backdrop/material layers render transparent, so the
    /// context is pre-filled with the window background.
    @MainActor
    static func renderLayerTree(of view: NSView, scale: CGFloat) -> Data? {
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
}
