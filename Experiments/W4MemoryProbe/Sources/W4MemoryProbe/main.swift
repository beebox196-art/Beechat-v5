// W4 Memory Probe — quantifies the risk-analysis claim that LazyVStack + per-bubble
// web views accumulate without bound. Mirrors MessageCanvas's container shape
// (ScrollView + LazyVStack) with 500 mixed-content messages.
//
// Run:  swift run  (from Experiments/W4MemoryProbe)
// Compare renderers with the toolbar picker; drive instantiation with "Auto-scroll".
// Watch: in-app footprint readout + "Web Content" processes in Activity Monitor.
// Pass/fail thresholds: see README.md.

import SwiftUI
import MarkdownWebView

// MARK: - Sample corpus (mix mirrors real agent output)

let corpus: [String] = {
    let templates = [
        "Quick answer: the gateway reconnects automatically after **\(Int.random(in: 2...9))s**. Nothing to do on your side.",

        """
        Here's the fix for the crash:

        ```swift
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            templateReady = false
            webView.loadHTMLString(template, baseURL: nil)
        }
        ```

        The WebContent process was dying under memory pressure and the bubble stayed blank.
        """,

        """
        | Component | Tests | Status |
        |-----------|-------|--------|
        | Persistence | 27 | ✅ |
        | Gateway | 48 | ✅ |
        | SyncBridge | 37 | ✅ |
        | App | 14 | ✅ |
        """,

        """
        Three options, ranked:

        1. **Native conversion** — best memory, best a11y
        2. *Single web view* — good perf, high maintenance
           - requires DOM windowing
           - loses native selection
        3. Per-bubble web view — simplest to start, worst at scale

        > The gap widens on macOS because of live window resize.
        """,

        String(repeating: "This is a longer paragraph of ordinary prose to vary bubble heights. ",
               count: Int.random(in: 3...12)),
    ]
    return (0..<500).map { i in "**Message \(i)** — \(templates[i % templates.count])" }
}()

// MARK: - Memory readout

func physFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / 1_048_576
}

// MARK: - Probe UI

enum Renderer: String, CaseIterable {
    case webview = "markdown-webview"
    case native = "native Text (baseline)"
}

// --auto: run the full scroll unattended, print samples to stdout, self-terminate.
// --renderer webview|native selects the renderer under test.
let autoMode = CommandLine.arguments.contains("--auto")
let cliRenderer: Renderer = {
    guard let i = CommandLine.arguments.firstIndex(of: "--renderer"),
          i + 1 < CommandLine.arguments.count,
          CommandLine.arguments[i + 1] == "native" else { return .webview }
    return .native
}()

struct ProbeView: View {
    @State private var renderer: Renderer = cliRenderer
    @State private var footprint = physFootprintMB()
    @State private var peak: Double = 0
    @State private var autoScrolling = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            // Same container shape as MessageCanvas: ScrollView + LazyVStack.
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(corpus.indices, id: \.self) { i in
                        bubble(corpus[i])
                            .frame(maxWidth: 560, alignment: .leading)
                            .padding(.horizontal, 16)
                            .id(i)
                    }
                }
                .padding(.vertical, 12)
            }
            .toolbar {
                ToolbarItemGroup {
                    Picker("Renderer", selection: $renderer) {
                        ForEach(Renderer.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    Button(autoScrolling ? "Scrolling…" : "Auto-scroll all 500") {
                        autoScroll(proxy)
                    }
                    .disabled(autoScrolling)
                    Text(String(format: "app: %.0f MB   peak: %.0f MB", footprint, peak))
                        .monospacedDigit()
                }
            }
            .onAppear { if autoMode { runAutoAndExit(proxy) } }
        }
        .onReceive(timer) { _ in
            footprint = physFootprintMB()
            peak = max(peak, footprint)
            if autoMode { print(String(format: "sample footprint_mb=%.0f", footprint)) }
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    private func runAutoAndExit(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3)) // let first screen settle
            print(String(format: "start renderer=%@ footprint_mb=%.0f",
                         renderer.rawValue, physFootprintMB()))
            autoScroll(proxy)
            while autoScrolling { try? await Task.sleep(for: .seconds(1)) }
            try? await Task.sleep(for: .seconds(10)) // settle/plateau window
            print(String(format: "FINAL renderer=%@ settled_mb=%.0f peak_mb=%.0f",
                         renderer.rawValue, physFootprintMB(), max(peak, physFootprintMB())))
            exit(0)
        }
    }

    @ViewBuilder
    private func bubble(_ content: String) -> some View {
        Group {
            switch renderer {
            case .webview:
                MarkdownWebView(content)
            case .native:
                Text(try! AttributedString(
                    markdown: content,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    // Steps through the transcript to force LazyVStack to instantiate every bubble —
    // the W4 scenario. ~25s total.
    private func autoScroll(_ proxy: ScrollViewProxy) {
        autoScrolling = true
        Task { @MainActor in
            for i in stride(from: 0, through: corpus.count - 1, by: 10) {
                withAnimation(.linear(duration: 0.3)) { proxy.scrollTo(i, anchor: .top) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            autoScrolling = false
        }
    }
}

// MARK: - App bootstrap (SPM executable needs manual activation)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct W4MemoryProbeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup("W4 Memory Probe — 500 messages") {
            ProbeView()
        }
    }
}

/// Auto mode bypasses the SwiftUI scene machinery: when launched from a background
/// shell, macOS 14 cooperative activation leaves a WindowGroup's window unmapped, so
/// onAppear never fires. A manual NSWindow + NSHostingView shown via
/// orderFrontRegardless() attaches and appears the view without needing activation.
final class AutoRunDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 640),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.title = "W4 Memory Probe (auto)"
        w.contentView = NSHostingView(rootView: ProbeView())
        w.orderFrontRegardless()
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 150) {
            print("WATCHDOG: auto run did not complete in 150s")
            exit(2)
        }
    }
}

if autoMode {
    setbuf(stdout, nil) // progress lines must reach the redirected log immediately
    let app = NSApplication.shared
    let delegate = AutoRunDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
} else {
    W4MemoryProbeApp.main()
}
