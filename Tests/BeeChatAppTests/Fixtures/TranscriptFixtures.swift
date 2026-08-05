import Foundation

/// Fixture corpus for the single-WebView transcript (WP-2 §9).
///
/// Two sources combined:
///
/// 1. **The 18-case converter matrix** — each case is sanitized HTML produced by
///    `MarkdownToHTML.convert()` + `HTMLSanitizer.sanitize()` for a representative
///    input. This is the same matrix `HTMLMessageConverterTests.swift` exercises
///    against the native rendering path; we re-use it here to prove the .web
///    engine renders each case without error or layout collapse.
///
/// 2. **General's real window (25 messages, synthetic)** — a small but realistic
///    chat transcript simulating what the General topic looks like (a mix of user
///    questions, assistant replies with code blocks, a table, lists, and system
///    messages). We cannot pull the real DB in a unit-test target, so this
///    fixture approximates the General topic's shape. When WP-3 wires the real
///    host, the same fixture will be replaced by a GRDB-backed loader (route
///    plan §3 G1 used the real DB; WP-2's contract test uses synthetic data
///    per E4 — fixtures must be reproducible, the GRDB query lives in WP-3).
///
/// E4 compliance: every fixture here is a hardcoded JSON literal in the test
/// source, NOT derived from runtime state. Reproducibility: any reviewer can
/// rebuild this file byte-for-byte from the spec.
enum TranscriptFixtures {

    // MARK: - The 18-case converter matrix
    //
    // Each case is `(name, role, sanitizedHTML)`. The HTML has already been
    // through MarkdownToHTML → HTMLSanitizer, mirroring the production pipeline.
    // The names correspond to the converter test cases so an operator can map
    // a fixture failure back to a converter test for triage.

    static let converterMatrix: [(name: String, role: String, html: String)] = [
        ("simple-paragraph", "assistant", "<p>Hello, world.</p>"),
        ("bare-text", "assistant", "<p>Just some plain text with no tags.</p>"),
        ("multiple-paragraphs", "assistant",
         "<p>First paragraph here.</p><p>Second paragraph here.</p>"),
        ("headings", "assistant",
         "<h1>Heading 1</h1><h2>Heading 2</h2><h3>Heading 3</h3>"),
        ("heading-level-maps", "assistant",
         "<h1>Top</h1><h2>Sub</h2><h3>Sub-sub</h3>"),
        ("bold", "assistant", "<p>This has <strong>bold</strong> text.</p>"),
        ("italic", "assistant", "<p>This has <em>italic</em> text.</p>"),
        ("strikethrough", "assistant", "<p>This has <del>struck</del> text.</p>"),
        ("inline-code", "assistant", "<p>Use <code>foo()</code> to call foo.</p>"),
        ("link", "assistant",
         "<p>Visit <a href=\"https://example.com\">Example</a> for details.</p>"),
        ("underline", "assistant", "<p>This has <u>underlined</u> text.</p>"),
        ("bold-italic", "assistant",
         "<p>Mix of <strong><em>bold italic</em></strong> here.</p>"),
        ("code-block", "assistant",
         "<pre><code class=\"language-swift\">let x = 42\nprint(x)\n</code></pre>"),
        ("code-block-no-lang", "assistant",
         "<pre><code>plain code\nno language hint\n</code></pre>"),
        ("pre-without-code", "assistant",
         "<pre>plain preformatted text</pre>"),
        ("unordered-list", "assistant",
         "<ul><li>First item</li><li>Second item</li><li>Third item</li></ul>"),
        ("ordered-list", "assistant",
         "<ol><li>One</li><li>Two</li><li>Three</li></ol>"),
        ("blockquote", "assistant",
         "<blockquote><p>A wise saying.</p></blockquote>"),
        ("image", "assistant",
         "<p><img src=\"https://example.com/foo.png\" alt=\"Example image\" /></p>"),
        ("image-broken", "assistant",
         "<p><img src=\"https://invalid.test/missing.png\" alt=\"Will fail\" /></p>"),
        ("horizontal-rule", "assistant",
         "<p>Before</p><hr><p>After</p>"),
        ("mixed-content", "assistant",
         "<h2>Title</h2><p>Intro paragraph with <strong>bold</strong> and <a href=\"https://example.com\">a link</a>.</p><pre><code>let x = 1</code></pre><ul><li>Item 1</li><li>Item 2</li></ul><blockquote><p>Quoted.</p></blockquote><hr><p>Final paragraph.</p>"),
        ("line-break", "assistant",
         "<p>Line one<br>Line two<br>Line three</p>"),
        ("nested-formatting", "assistant",
         "<p>Plain <strong>bold <em>and italic</em></strong> back to bold.</p>"),
    ]

    // MARK: - General's real window — synthetic 25-message fixture
    //
    // Models the shape of a real General topic: user questions, assistant replies
    // with code + tables + lists, system messages, occasional long-form answers.
    // Sanitized HTML — no scripts, no inline event handlers.

    static let generalWindow: [[String: Any]] = [
        ["id": "g1", "role": "user", "timeLabel": "09:01",
         "html": "<p>Hey Bee, can you help me think through an architecture decision?</p>"],
        ["id": "g2", "role": "assistant", "senderName": "Bee", "timeLabel": "09:02",
         "html": "<p>Of course — happy to think it through with you. What's the context?</p>"],
        ["id": "g3", "role": "user", "timeLabel": "09:03",
         "html": "<p>I'm deciding between a single WKWebView transcript (Option B) and keeping the native scroll path. Trade-offs?</p>"],
        ["id": "g4", "role": "assistant", "senderName": "Bee", "timeLabel": "09:04",
         "html": """
         <p>The short version: one <code>WKWebView</code> removes a whole class of bugs.</p>
         <p>Long version:</p>
         <ul>
         <li><strong>Heights live in the same layout engine as scroll offset.</strong> That makes the R1/R2/R4/whitespace-stranding bug class <em>unrepresentable</em> — no async height bridge means no drift.</li>
         <li>Topic switch becomes one synchronous DOM swap + scroll-to-bottom. No <code>.id(topicId)</code> remount, no white flash.</li>
         <li>HTML fidelity is free: tables, code blocks, anything. No converter subset to maintain.</li>
         </ul>
         <p>The native path's only real advantage today is the 17-process overhead is well-understood. That's not a technical advantage, just familiarity.</p>
         """],
        ["id": "g5", "role": "user", "timeLabel": "09:05",
         "html": "<p>What about the streaming-bubble settling handoff? That's been flaky for months.</p>"],
        ["id": "g6", "role": "assistant", "senderName": "Bee", "timeLabel": "09:06",
         "html": "<p>In Option B the chain collapses:</p><pre><code>// Today: 3 webviews, 2 cold remounts\nstreaming -&gt; bridge -&gt; settled\n\n// Option B: one in-place update\nsetStreaming(null);  // remove the streaming node\nupsertMessages([settled]);  // insert the settled node\n</code></pre><p>No remount, no flash. The settled message arrives via the same code path as any other upsert.</p>"],
        ["id": "g7", "role": "system", "timeLabel": "09:07",
         "html": "<p>Context reset by user.</p>"],
        ["id": "g8", "role": "user", "timeLabel": "09:08",
         "html": "<p>OK, let's do Option B. Where do we start?</p>"],
        ["id": "g9", "role": "assistant", "senderName": "Bee", "timeLabel": "09:09",
         "html": "<p>Three work packages:</p><ol><li><strong>WP-0</strong>: feasibility spike with six gates G1-G6. Validates the premise with real evidence before committing.</li><li><strong>WP-1</strong>: transcript boundary refactor. Pure structure; native engine kept, web engine stubbed.</li><li><strong>WP-2</strong>: the transcript document itself - this is what we're building now.</li></ol><p>WP-0 has to PASS all six gates before WP-2 starts.</p>"],
        ["id": "g10", "role": "user", "timeLabel": "09:10",
         "html": "<p>Got it. What about copy-paste — can I still Cmd+C across messages?</p>"],
        ["id": "g11", "role": "assistant", "senderName": "Bee", "timeLabel": "09:11",
         "html": "<p>Yes - and it's actually <em>better</em> in Option B. The current native transcript snaps selection to a single rendered line, so multi-line copy across messages is impossible. In the single-document WebView, native browser selection across the whole transcript is free. We add explicit copy buttons for code blocks and per-message copy-full-text as affordances.</p><p>Acceptance: A1 cross-message drag-select, A2 code-block copy, A3 per-message copy, A4 no selection interference from the scroll engine, A5 paste-verified into TextEdit.</p>"],
        ["id": "g12", "role": "user", "timeLabel": "09:12",
         "html": "<p>Performance? 17 WebContent processes feels like a lot.</p>"],
        ["id": "g13", "role": "assistant", "senderName": "Bee", "timeLabel": "09:13",
         "html": "<p>Option B is exactly <strong>one</strong> WebContent process, app-lifetime. WP-0 G1 measured 1 process / 422 messages / &lt; 400 MB total RSS across a 30-minute soak. The 17/79 numbers are symptoms of the per-bubble webview pattern, not WKWebView itself.</p>"],
        ["id": "g14", "role": "user", "timeLabel": "09:14",
         "html": "<p>Tables? The current converter bails out for tables.</p>"],
        ["id": "g15", "role": "assistant", "senderName": "Bee", "timeLabel": "09:15",
         "html": "<p>WebKit handles them natively. Here's the converter matrix:</p><table><thead><tr><th>Component</th><th>Tests</th><th>Status</th></tr></thead><tbody><tr><td>Persistence</td><td>27</td><td>OK</td></tr><tr><td>Gateway</td><td>48</td><td>OK</td></tr><tr><td>SyncBridge</td><td>37</td><td>OK</td></tr><tr><td>App</td><td>14</td><td>OK</td></tr></tbody></table><p>Tables, code blocks, blockquotes, images - all native.</p>"],
        ["id": "g16", "role": "user", "timeLabel": "09:16",
         "html": "<p>Risks? What keeps me up at night?</p>"],
        ["id": "g17", "role": "assistant", "senderName": "Bee", "timeLabel": "09:17",
         "html": "<p>Honestly:</p><ul><li><strong>Theme port fidelity across 8 themes.</strong> Tokens already exist; screenshot-diff per theme catches regressions.</li><li><strong>Focus/keyboard interplay</strong> between the native composer and the web transcript. WP-0 G6 already validated this on the spike - composer kept focus through streaming.</li><li><strong>VoiceOver parity.</strong> Native bubbles announce slightly differently than web <code>role=\"log\"</code>. Acceptable trade.</li></ul><p>Nothing here is a surprise. The spike is what proves them.</p>"],
        ["id": "g18", "role": "user", "timeLabel": "09:18",
         "html": "<p>Effort?</p>"],
        ["id": "g19", "role": "assistant", "senderName": "Bee", "timeLabel": "09:19",
         "html": "<p>About two working weeks to flag-on:</p><table><thead><tr><th>Phase</th><th>Days</th></tr></thead><tbody><tr><td>B-0 spike gates</td><td>2-3</td></tr><tr><td>B-1 boundary refactor</td><td>0.5</td></tr><tr><td>B-2 transcript document</td><td>2-3</td></tr><tr><td>B-3 Swift host + bridge</td><td>2</td></tr><tr><td>B-4 parity + hardening</td><td>2-3</td></tr></tbody></table><p>Net code: ~710 lines added, ~1900 lines deleted at retirement.</p>"],
        ["id": "g20", "role": "user", "timeLabel": "09:20",
         "html": "<p>What about the 8 themes? Do they all port cleanly?</p>"],
        ["id": "g21", "role": "assistant", "senderName": "Bee", "timeLabel": "09:21",
         "html": "<p>The 8 themes are: artisanal-tech, dark, light, starfleet-lcars, minimal, holographic-imperial, water-fluid-ui, living-crystal. All theming flows through the same <code>--bc-*</code> CSS custom properties that <code>ThemeManager.cssTokens</code> already pushes. The WebView template just consumes those tokens - no per-theme CSS.</p>"],
        ["id": "g22", "role": "user", "timeLabel": "09:22",
         "html": "<p>Last question: if a user reports whitespace after a long session, what changed?</p>"],
        ["id": "g23", "role": "assistant", "senderName": "Bee", "timeLabel": "09:23",
         "html": "<p>Nothing - the bug class becomes <em>unrepresentable</em>. Heights and scroll offset live in the same layout engine. There is no async height bridge for them to drift across. If we ever see whitespace in Option B, it's a P0 because it means we re-introduced the boundary.</p>"],
        ["id": "g24", "role": "system", "timeLabel": "09:24",
         "html": "<p>Conversation saved.</p>"],
        ["id": "g25", "role": "user", "timeLabel": "09:25",
         "html": "<p>Thanks Bee. Going to ship this.</p>"],
    ]

    // MARK: - The 8 themes — CSS token palettes
    //
    // These mirror Theme.swift's eight ThemeDefinitions (artisanal-tech, dark,
    // light, starfleet-lcars, minimal, holographic-imperial, water-fluid-ui,
    // living-crystal). We hardcode the CSS tokens here so the test is fully
    // reproducible WITHOUT needing ThemeManager.shared. The values are taken
    // from Theme.swift's color dictionaries (verified manually).
    //
    // WP-3 wires ThemeManager to feed setTheme() at runtime; WP-2's contract
    // test uses these hardcoded values to prove the document accepts them.

    static let allThemes: [(name: String, tokens: [String: String])] = [
        ("artisanal-tech", [
            "--bc-appearance": "light",
            "--bc-bg-surface": "#F8F6F0",
            "--bc-bg-panel": "#EAE6DF",
            "--bc-bg-elevated": "#FFFFFF",
            "--bc-text": "#2D2D2D",
            "--bc-text-dim": "#6B6B6B",
            "--bc-text-on-accent": "#FFFFFF",
            "--bc-accent": "#D4A574",
            "--bc-accent-secondary": "#8FA895",
            "--bc-accent-tertiary": "#C77D63",
            "--bc-code-border": "#E0E0E0",
            "--bc-table-border": "#BDBDBD",
            "--bc-link": "#8A6420",
            "--bc-code-bg": "#EAE6DF",
            "--bc-quote-bar": "#D4A574",
            "--bc-hr": "#BDBDBD",
            "--bc-radius-bubble": "16px",
            "--bc-pad-h-bubble": "16px",
            "--bc-pad-v-bubble": "12px",
            "--bc-gap-msg": "4px",
            "--bc-shadow-bubble": "rgba(0,0,0,0.05) 0.0px 1.0px 2.0px, rgba(0,0,0,0.1) 0.0px 4.0px 6.0px",
            "--bc-font-scale": "1.0",
        ]),
        ("dark", [
            "--bc-appearance": "dark",
            "--bc-bg-surface": "#121212",
            "--bc-bg-panel": "#1E1E1E",
            "--bc-bg-elevated": "#2A2A2A",
            "--bc-text": "#E0E0E0",
            "--bc-text-dim": "#9E9E9E",
            "--bc-text-on-accent": "#FFFFFF",
            "--bc-accent": "#64B5F6",
            "--bc-accent-secondary": "#81C784",
            "--bc-accent-tertiary": "#FFB74D",
            "--bc-code-border": "#2A2A2A",
            "--bc-table-border": "#424242",
            "--bc-link": "#E8C583",
            "--bc-code-bg": "#1E1E1E",
            "--bc-quote-bar": "#64B5F6",
            "--bc-hr": "#424242",
            "--bc-radius-bubble": "16px",
            "--bc-pad-h-bubble": "16px",
            "--bc-pad-v-bubble": "12px",
            "--bc-gap-msg": "4px",
            "--bc-shadow-bubble": "rgba(0,0,0,0.05) 0.0px 1.0px 2.0px, rgba(0,0,0,0.1) 0.0px 4.0px 6.0px",
            "--bc-font-scale": "1.0",
        ]),
        ("light", [
            "--bc-appearance": "light",
            "--bc-bg-surface": "#FAFAFA",
            "--bc-bg-panel": "#F0F0F0",
            "--bc-bg-elevated": "#FFFFFF",
            "--bc-text": "#212121",
            "--bc-text-dim": "#6B6B6B",
            "--bc-text-on-accent": "#FFFFFF",
            "--bc-accent": "#1976D2",
            "--bc-accent-secondary": "#388E3C",
            "--bc-accent-tertiary": "#F57C00",
            "--bc-code-border": "#E0E0E0",
            "--bc-table-border": "#BDBDBD",
            "--bc-link": "#0D47A1",
            "--bc-code-bg": "#F0F0F0",
            "--bc-quote-bar": "#1976D2",
            "--bc-hr": "#BDBDBD",
            "--bc-radius-bubble": "16px",
            "--bc-pad-h-bubble": "16px",
            "--bc-pad-v-bubble": "12px",
            "--bc-gap-msg": "4px",
            "--bc-shadow-bubble": "rgba(0,0,0,0.05) 0.0px 1.0px 2.0px, rgba(0,0,0,0.1) 0.0px 4.0px 6.0px",
            "--bc-font-scale": "1.0",
        ]),
        ("starfleet-lcars", [
            "--bc-appearance": "dark",
            "--bc-bg-surface": "#00002E",
            "--bc-bg-panel": "#0A0A4A",
            "--bc-bg-elevated": "#1A1A6A",
            "--bc-text": "#FFCC99",
            "--bc-text-dim": "#CC9966",
            "--bc-text-on-accent": "#000000",
            "--bc-accent": "#FF6600",
            "--bc-accent-secondary": "#9999CC",
            "--bc-accent-tertiary": "#FFAA66",
            "--bc-code-border": "#9999CC",
            "--bc-table-border": "#9999CC",
            "--bc-link": "#FFCC99",
            "--bc-code-bg": "#0A0A4A",
            "--bc-quote-bar": "#FF6600",
            "--bc-hr": "#9999CC",
            "--bc-radius-bubble": "4px",
            "--bc-pad-h-bubble": "16px",
            "--bc-pad-v-bubble": "12px",
            "--bc-gap-msg": "4px",
            "--bc-shadow-bubble": "rgba(255,102,0,0.3) 0.0px 0.0px 8.0px",
            "--bc-font-scale": "1.0",
        ]),
        ("minimal", [
            "--bc-appearance": "light",
            "--bc-bg-surface": "#FFFFFF",
            "--bc-bg-panel": "#FAFAFA",
            "--bc-bg-elevated": "#FFFFFF",
            "--bc-text": "#111111",
            "--bc-text-dim": "#666666",
            "--bc-text-on-accent": "#FFFFFF",
            "--bc-accent": "#111111",
            "--bc-accent-secondary": "#444444",
            "--bc-accent-tertiary": "#888888",
            "--bc-code-border": "#EEEEEE",
            "--bc-table-border": "#DDDDDD",
            "--bc-link": "#333333",
            "--bc-code-bg": "#FAFAFA",
            "--bc-quote-bar": "#111111",
            "--bc-hr": "#DDDDDD",
            "--bc-radius-bubble": "0px",
            "--bc-pad-h-bubble": "12px",
            "--bc-pad-v-bubble": "8px",
            "--bc-gap-msg": "2px",
            "--bc-shadow-bubble": "none",
            "--bc-font-scale": "1.0",
        ]),
        ("holographic-imperial", [
            "--bc-appearance": "dark",
            "--bc-bg-surface": "#0A0A1A",
            "--bc-bg-panel": "#14143A",
            "--bc-bg-elevated": "#1E1E55",
            "--bc-text": "#E0E0FF",
            "--bc-text-dim": "#9999CC",
            "--bc-text-on-accent": "#0A0A1A",
            "--bc-accent": "#00FFFF",
            "--bc-accent-secondary": "#9966FF",
            "--bc-accent-tertiary": "#FF66CC",
            "--bc-code-border": "#9966FF",
            "--bc-table-border": "#9966FF",
            "--bc-link": "#00CCCC",
            "--bc-code-bg": "#14143A",
            "--bc-quote-bar": "#00FFFF",
            "--bc-hr": "#9966FF",
            "--bc-radius-bubble": "12px",
            "--bc-pad-h-bubble": "16px",
            "--bc-pad-v-bubble": "12px",
            "--bc-gap-msg": "4px",
            "--bc-shadow-bubble": "rgba(0,255,255,0.3) 0.0px 0.0px 12.0px",
            "--bc-font-scale": "1.0",
        ]),
        ("water-fluid-ui", [
            "--bc-appearance": "light",
            "--bc-bg-surface": "#E8F4FD",
            "--bc-bg-panel": "#D0E8F8",
            "--bc-bg-elevated": "#FFFFFF",
            "--bc-text": "#023E5C",
            "--bc-text-dim": "#3D6E89",
            "--bc-text-on-accent": "#FFFFFF",
            "--bc-accent": "#0077B6",
            "--bc-accent-secondary": "#00B4D8",
            "--bc-accent-tertiary": "#90E0EF",
            "--bc-code-border": "#90E0EF",
            "--bc-table-border": "#90E0EF",
            "--bc-link": "#023E5C",
            "--bc-code-bg": "#D0E8F8",
            "--bc-quote-bar": "#0077B6",
            "--bc-hr": "#90E0EF",
            "--bc-radius-bubble": "20px",
            "--bc-pad-h-bubble": "18px",
            "--bc-pad-v-bubble": "14px",
            "--bc-gap-msg": "6px",
            "--bc-shadow-bubble": "rgba(0,119,182,0.15) 0.0px 2.0px 8.0px",
            "--bc-font-scale": "1.0",
        ]),
        ("living-crystal", [
            "--bc-appearance": "light",
            "--bc-bg-surface": "#F5F0FA",
            "--bc-bg-panel": "#E8DFF5",
            "--bc-bg-elevated": "#FFFFFF",
            "--bc-text": "#2D1B5C",
            "--bc-text-dim": "#6B4D8C",
            "--bc-text-on-accent": "#FFFFFF",
            "--bc-accent": "#8B5CF6",
            "--bc-accent-secondary": "#EC4899",
            "--bc-accent-tertiary": "#A78BFA",
            "--bc-code-border": "#C4B5FD",
            "--bc-table-border": "#C4B5FD",
            "--bc-link": "#6D28D9",
            "--bc-code-bg": "#E8DFF5",
            "--bc-quote-bar": "#8B5CF6",
            "--bc-hr": "#C4B5FD",
            "--bc-radius-bubble": "16px",
            "--bc-pad-h-bubble": "16px",
            "--bc-pad-v-bubble": "12px",
            "--bc-gap-msg": "4px",
            "--bc-shadow-bubble": "rgba(139,92,246,0.2) 0.0px 4.0px 12.0px",
            "--bc-font-scale": "1.0",
        ]),
    ]
}
