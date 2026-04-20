import SwiftUI

/// Finds all NSVisualEffectViews in the key window and replaces their backgrounds
/// with the theme colour. On macOS, NavigationSplitView injects visual effect views
/// that override SwiftUI .background() modifiers.
///
/// Usage: place as an overlay on the view whose parent hierarchy needs fixing.
struct WindowBackgroundFix: NSViewRepresentable {
    let nsColor: NSColor

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        // Delay to allow the window's view hierarchy to be fully constructed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            applyFix(from: v)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            applyFix(from: nsView)
        }
    }

    private func applyFix(from view: NSView) {
        // Find the window
        guard let window = view.window else { return }
        let contentView = window.contentView ?? view
        // Debug: dump the sidebar area view hierarchy
        dumpHierarchy(contentView, depth: 0)
        fixVisualEffects(in: contentView)
        fixScrollViews(in: contentView)
        fixTableViews(in: contentView)
        fixGenericViews(in: contentView)
    }

    private func dumpHierarchy(_ view: NSView, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        let className = String(describing: type(of: view))
        let frame = view.frame
        let hasLayer = view.wantsLayer
        var layerColor = "none"
        if hasLayer, let bg = view.layer?.backgroundColor {
            layerColor = String(describing: bg)
        }
        print("\(indent)\(className) frame=\(frame) wantsLayer=\(hasLayer) layerBg=\(layerColor)")
        for sub in view.subviews {
            dumpHierarchy(sub, depth: depth + 1)
        }
    }

    private func fixVisualEffects(in view: NSView) {
        if let effectView = view as? NSVisualEffectView {
            effectView.state = .inactive
            effectView.isEmphasized = false
            effectView.wantsLayer = true
            effectView.layer?.backgroundColor = nsColor.cgColor
            // Also set material to a solid one
            effectView.material = .windowBackground
        }
        for sub in view.subviews {
            fixVisualEffects(in: sub)
        }
    }

    private func fixScrollViews(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            scrollView.drawsBackground = false
            scrollView.wantsLayer = true
            scrollView.layer?.backgroundColor = nsColor.cgColor
            scrollView.contentView.wantsLayer = true
            scrollView.contentView.layer?.backgroundColor = nsColor.cgColor
            scrollView.contentView.drawsBackground = false
            // Also fix the document view
            scrollView.documentView?.wantsLayer = true
            if let docLayer = scrollView.documentView?.layer {
                docLayer.backgroundColor = nsColor.cgColor
            }
        }
        for sub in view.subviews {
            fixScrollViews(in: sub)
        }
    }

    private func fixTableViews(in view: NSView) {
        if let tableView = view as? NSTableView {
            tableView.backgroundColor = nsColor
            tableView.wantsLayer = true
            tableView.layer?.backgroundColor = nsColor.cgColor
            tableView.style = .plain
        }
        for sub in view.subviews {
            fixTableViews(in: sub)
        }
    }

    private func fixGenericViews(in view: NSView) {
        // Only override generic views that are clearly system grey backgrounds
        // within the window's content area
        if view !== view.window?.contentView,
           view.wantsLayer,
           let layer = view.layer,
           let bg = layer.backgroundColor {
            let numComps = Int(bg.numberOfComponents)
            if numComps >= 3, let comps = bg.components {
                let r = comps[0], g = comps[1], b = comps[2]
                // Only override near-white system greys (macOS default window bg)
                let isSystemGrey = r > 0.9 && r < 1.0
                    && abs(r - g) < 0.02
                    && abs(g - b) < 0.02
                if isSystemGrey {
                    layer.backgroundColor = nsColor.cgColor
                }
            }
        }
        for sub in view.subviews {
            fixGenericViews(in: sub)
        }
    }
}