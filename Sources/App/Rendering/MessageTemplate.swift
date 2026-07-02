import Foundation
import os

/// Embedded HTML template for MessageWebView.
///
/// This eliminates the resource-bundle lookup entirely — the template is a
/// compile-time constant, so it can never crash on a missing file. The original
/// `MessageTemplate.html` file is kept in `Resources/` for development reference
/// and Xcode builds (where SPM resource bundles work normally), but the hand-assembled
/// `.app` bundle used by `scripts/build-and-install.sh` depends solely on this constant.
///
/// ## Updating the template
///
/// After editing `Resources/MessageTemplate.html`, regenerate this constant by running:
///
///     swift scripts/embed-template.swift
///
/// (The script reads the .html file and writes this Swift file with the escaped string.)
/// Alternatively, manually paste the HTML content into the string literal below.
///
/// The template is intentionally small (~8 KB) and rarely changes, so embedding is
/// preferable to runtime bundle resolution which is fragile in hand-assembled app bundles.
enum MessageTemplate {

    private static let logger = Logger(subsystem: "com.beebox.beechat", category: "MessageTemplate")

    /// The complete HTML template as a string. Loaded at init time (once per process).
    /// Resolution chain: SPM resource bundle → flat Bundle.main → embedded fallback constant.
    /// Never crashes — if no resource file is found, the embedded constant is used.
    static let html: String = {
        // Try SPM resource bundle by scanning Resources/ for .bundle directories.
        // This works for Xcode builds and `swift build` where the bundle is co-located.
        if let resourceURL = Bundle.main.resourceURL {
            let fm = FileManager.default
            if let contents = try? fm.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil) {
                for url in contents where url.pathExtension == "bundle" && url.lastPathComponent.contains("BeeChatApp") {
                    if let bundle = Bundle(url: url),
                       let htmlURL = bundle.url(forResource: "MessageTemplate", withExtension: "html"),
                       let content = try? String(contentsOf: htmlURL, encoding: .utf8) {
                        logger.info("Template loaded from SPM resource bundle: \(url.lastPathComponent)")
                        return content
                    }
                }
            }
        }

        // Try Bundle.main directly (for hand-assembled .app bundles that copy the file flat)
        if let url = Bundle.main.url(forResource: "MessageTemplate", withExtension: "html"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            logger.info("Template loaded from Bundle.main flat resource")
            return content
        }

        // Embedded fallback — guaranteed available, never crashes.
        // KEEP IN SYNC WITH: Sources/App/Resources/MessageTemplate.html
        // REGENERATE WITH: swift scripts/embed-template.swift
        logger.warning("No resource bundle or flat file found for MessageTemplate.html — using embedded fallback")
        return embeddedTemplate
    }()

    // MARK: - Embedded Template

    /// Hardcoded fallback template. This is the authoritative source for hand-assembled
    /// app bundles where SPM resource bundles are not available.
    private static let embeddedTemplate = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<style>
  :root {
    color-scheme: light dark;
    --bc-font-base: 13;
    --bc-font-scale: 1;
    --bc-accent:       #D4A574;
    --bc-text:         #212121;
    --bc-text-dim:     rgba(33, 33, 33, 0.55);
    --bc-link:         #8A6420;
    --bc-code-bg:      rgba(33, 33, 33, 0.06);
    --bc-code-border:  rgba(33, 33, 33, 0.12);
    --bc-quote-bar:    var(--bc-accent);
    --bc-table-border: rgba(33, 33, 33, 0.18);
    --bc-hr:           rgba(33, 33, 33, 0.15);
    --bc-img-broken:   rgba(33, 33, 33, 0.08);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bc-text:         #E0E0E0;
      --bc-text-dim:     rgba(224, 224, 224, 0.55);
      --bc-link:         #E8C583;
      --bc-code-bg:      rgba(224, 224, 224, 0.10);
      --bc-code-border:  rgba(224, 224, 224, 0.16);
      --bc-table-border: rgba(224, 224, 224, 0.22);
      --bc-hr:           rgba(224, 224, 224, 0.18);
      --bc-img-broken:   rgba(224, 224, 224, 0.10);
    }
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; background: transparent; height: auto; overflow: hidden; }
  body {
    font-family: -apple-system, "SF Pro Text", system-ui, sans-serif;
    font-size: calc(var(--bc-font-base) * var(--bc-font-scale) * 1px);
    color: var(--bc-text); line-height: 1.45; overflow-wrap: break-word; word-break: break-word;
    -webkit-user-select: text; cursor: default;
  }
  #content > :first-child { margin-top: 0; }
  #content > :last-child  { margin-bottom: 0; }
  p { margin: 0 0 0.6em; }
  a { color: var(--bc-link); text-decoration: none; cursor: pointer; }
  a:hover { text-decoration: underline; text-underline-offset: 2px; }
  strong, b { font-weight: 600; }
  h1, h2, h3, h4, h5, h6 { margin: 0.7em 0 0.35em; line-height: 1.25; font-weight: 700; }
  h1 { font-size: 1.35em; } h2 { font-size: 1.25em; } h3 { font-size: 1.15em; }
  h4, h5, h6 { font-size: 1.0em; }
  ul, ol { margin: 0.4em 0; padding-left: 1.4em; }
  li { margin: 0.15em 0; }
  li > ul, li > ol { margin: 0.15em 0; }
  blockquote { margin: 0.6em 0; padding: 2px 0 2px 10px; border-left: 3px solid var(--bc-quote-bar); color: var(--bc-text-dim); }
  code, pre { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.88em; }
  code { background: var(--bc-code-bg); border-radius: 4px; padding: 1px 4px; }
  pre { background: var(--bc-code-bg); border: 1px solid var(--bc-code-border); border-radius: 8px; padding: 8px 10px; overflow-x: auto; white-space: pre; }
  pre code { background: none; padding: 0; }
  img { max-width: 100%; height: auto; display: block; border-radius: 8px; margin: 0.4em 0; }
  img.bc-broken { min-width: 44px; min-height: 44px; background: var(--bc-img-broken); }
  .bc-scroll-x { overflow-x: auto; margin: 0.6em 0; }
  table { border-collapse: collapse; font-size: 0.92em; }
  th, td { border: 1px solid var(--bc-table-border); padding: 4px 8px; text-align: left; }
  th { font-weight: 600; }
  hr { border: none; border-top: 1px solid var(--bc-hr); margin: 0.8em 0; }
  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after { animation: none !important; transition: none !important; }
  }
</style>
</head>
<body>
<div id="content" dir="auto"></div>
<script>
(() => {
  'use strict';
  const content = document.getElementById('content');
  const bridge = (name, payload) => { try { window.webkit.messageHandlers[name].postMessage(payload); } catch (_) {} };
  let lastHeight = -1;
  const reportHeight = () => { const h = Math.ceil(content.getBoundingClientRect().height); if (h !== lastHeight) { lastHeight = h; bridge('bcHeight', h); } };
  new ResizeObserver(reportHeight).observe(content);
  const hydrate = () => {
    content.querySelectorAll('table').forEach((t) => { if (t.parentElement.classList.contains('bc-scroll-x')) return; const w = document.createElement('div'); w.className = 'bc-scroll-x'; t.replaceWith(w); w.appendChild(t); });
    content.querySelectorAll('img').forEach((img) => { if (img.complete) return; img.addEventListener('load', reportHeight, { once: true }); img.addEventListener('error', () => { img.classList.add('bc-broken'); if (!img.alt) img.alt = 'Image unavailable'; reportHeight(); }, { once: true }); });
    reportHeight();
  };
  document.addEventListener('click', (e) => { const a = e.target.closest('a[href]'); if (a) { e.preventDefault(); bridge('bcLink', a.href); return; } const img = e.target.closest('img:not(.bc-broken)'); if (img && img.src) bridge('bcImage', img.src); });
  document.addEventListener('contextmenu', (e) => e.preventDefault());
  window.beechat = {
    setContent(html) { content.innerHTML = html; hydrate(); },
    setTheme(tokens) { for (const [k, v] of Object.entries(tokens || {})) { if (k.startsWith('--bc-')) document.documentElement.style.setProperty(k, v); } },
    setFontScale(scale) { document.documentElement.style.setProperty('--bc-font-scale', String(scale)); },
  };
  bridge('bcReady', true);
})();
</script>
</body>
</html>
"""
}