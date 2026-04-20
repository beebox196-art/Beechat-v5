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
        guard let window = view.window else { return }
        let contentView = window.contentView ?? view
        fixVisualEffects(in: contentView)
        fixScrollViews(in: contentView)
        fixTableViews(in: contentView)
        fixSidebarGlass(in: contentView)
        fixGenericViews(in: contentView)
    }

    private func fixVisualEffects(in view: NSView) {
        if let effectView = view as? NSVisualEffectView {
            effectView.state = .inactive
            effectView.isEmphasized = false
            effectView.wantsLayer = true
            effectView.layer?.backgroundColor = nsColor.cgColor
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

    /// The sidebar column uses NSBlurryAlleywayView which renders a frosted-glass
    /// tint over its content. We can't simply override its layer or hide it because
    /// that breaks the compositing pipeline. Instead, we insert an opaque NSView
    /// *between* the NSBlurryAlleywayView and the NSContainerConcentricGlassEffectView
    /// (the content container). This paints our colour above the blur but below the
    /// actual list content, effectively replacing the tinted glass with our solid colour.
    private func fixSidebarGlass(in view: NSView) {
        let className = String(describing: type(of: view))

        if className.contains("NSBlurryAlleywayView") {
            // Find the NSContainerConcentricGlassEffectView (the content container)
            // and insert a solid fill between it and the alleyway view
            for sub in view.subviews {
                let subClass = String(describing: type(of: sub))
                if subClass.contains("NSContainerConcentricGlassEffectView") {
                    let fillView = NSView(frame: view.bounds)
                    fillView.wantsLayer = true
                    fillView.layer?.backgroundColor = nsColor.cgColor
                    fillView.autoresizingMask = [.width, .height]
                    // Insert the fill between the blur and the content
                    view.addSubview(fillView, positioned: .below, relativeTo: sub)
                    break
                }
            }
        }

        // Also set layer backgrounds on safe sidebar views
        let safeClasses = [
            "NSTitlebarBackgroundView",
            "ContentHolderView",
            "_NSScrollViewContentBackgroundView"
        ]
        if safeClasses.contains(where: { className.contains($0) }) {
            view.wantsLayer = true
            view.layer?.backgroundColor = nsColor.cgColor
        }

        for sub in view.subviews {
            fixSidebarGlass(in: sub)
        }
    }

    /// Override any remaining view with a greyish layer background
    private func fixGenericViews(in view: NSView) {
        if view.wantsLayer, let layer = view.layer, let bg = layer.backgroundColor {
            let numComps = Int(bg.numberOfComponents)
            if numComps >= 3, let comps = bg.components {
                let r = comps[0], g = comps[1], b = comps[2]
                let isSystemGrey = r > 0.85 && r < 1.0
                    && abs(r - g) < 0.05
                    && abs(g - b) < 0.05
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