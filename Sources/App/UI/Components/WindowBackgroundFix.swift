import SwiftUI

/// Finds all NSVisualEffectViews in the key window and replaces their backgrounds
/// with the theme colour. On macOS, NavigationSplitView injects visual effect views
/// that override SwiftUI .background() modifiers.
///
/// Strategy: The sidebar uses NSBlurryAlleywayView (a private AppKit frosted-glass view)
/// that cannot be overridden via layer backgrounds. We replace it entirely with a plain
/// NSView that has our theme colour as its layer background.
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

        // Set the window's background colour — this shows through translucent sidebar effects
        window.isOpaque = true
        window.backgroundColor = nsColor

        let contentView = window.contentView ?? view
        replaceSidebarGlass(in: contentView)
        fixVisualEffects(in: contentView)
        fixScrollViews(in: contentView)
        fixTableViews(in: contentView)
        fixGlassContainers(in: contentView)
        fixGenericViews(in: contentView)
    }

    /// Find and replace NSBlurryAlleywayView with a plain opaque NSView.
    /// This is the only reliable way to remove the system's frosted glass tint
    /// from the NavigationSplitView sidebar.
    private func replaceSidebarGlass(in view: NSView) {
        for (_, sub) in view.subviews.enumerated() {
            let className = String(describing: type(of: sub))

            if className.contains("NSBlurryAlleywayView") {
                // Create a replacement view with our theme colour
                let replacement = NSView(frame: sub.frame)
                replacement.wantsLayer = true
                replacement.layer?.backgroundColor = nsColor.cgColor
                replacement.autoresizingMask = sub.autoresizingMask
                replacement.identifier = NSUserInterfaceItemIdentifier("SidebarFill")

                // Re-parent all children of the alleyway view into the replacement
                let children = sub.subviews
                for child in children {
                    replacement.addSubview(child)
                }

                // Swap in the replacement
                view.replaceSubview(sub, with: replacement)
                return
            }

            // Recurse
            replaceSidebarGlass(in: sub)
        }
    }

    private func fixVisualEffects(in view: NSView) {
        if let effectView = view as? NSVisualEffectView {
            NSLog("[WindowBackgroundFix] Found NSVisualEffectView: frame=\(effectView.frame), material=\(effectView.material), state=\(effectView.state)")
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

    /// Override the glass container views that the sidebar column uses.
    /// NSContainerConcentricGlassEffectView and ContentHolderView render their own
    /// tinted backgrounds that override our SwiftUI .background() colour.
    /// We replace NSContainerConcentricGlassEffectView with a plain NSView,
    /// same as we do for NSBlurryAlleywayView.
    private func fixGlassContainers(in view: NSView) {
        let className = String(describing: type(of: view))

        if className.contains("NSContainerConcentricGlassEffectView") {
            NSLog("[WindowBackgroundFix] Found NSContainerConcentricGlassEffectView: frame=\(view.frame), children=\(view.subviews.count)")
            // Replace with a plain NSView
            let replacement = NSView(frame: view.frame)
            replacement.wantsLayer = true
            replacement.layer?.backgroundColor = nsColor.cgColor
            replacement.autoresizingMask = view.autoresizingMask
            let children = view.subviews
            for child in children {
                replacement.addSubview(child)
            }
            if let superview = view.superview {
                superview.replaceSubview(view, with: replacement)
                NSLog("[WindowBackgroundFix] Replaced NSContainerConcentricGlassEffectView")
            }
            return
        }

        if className.contains("ContentHolderView") {
            view.wantsLayer = true
            view.layer?.backgroundColor = nsColor.cgColor
        }

        for sub in view.subviews {
            fixGlassContainers(in: sub)
        }
    }

    /// Override any remaining view with a greyish layer background
    private func fixGenericViews(in view: NSView) {
        let className = String(describing: type(of: view))

        // Override the split view item wrapper's background
        if className.contains("_NSSplitViewItemViewWrapper") {
            view.wantsLayer = true
            view.layer?.backgroundColor = nsColor.cgColor
        }

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