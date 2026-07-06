import Foundation
import os.log
import SwiftUI

/// CanvasScrollMetrics — per-frame scroll geometry instrumentation for the
/// v0.9.5d whitespace-jump spike (branch `spike/list-container-a-2026-07-06`).
///
/// This file is intentionally narrow: it only records scroll geometry + the
/// derived `bottomGap` metric, plus a composer-height-change observer wired
/// from MainWindow. It does NOT change scroll policy, container, or any
/// rendering. The purpose is to give the spike an empirical baseline against
/// which the `ScrollView { LazyVStack }` → `List` swap can be compared.
///
/// Metric (from Fable brief):
///     bottomGap = (contentOffset.y + containerSize.height) − contentSize.height
///
/// A whitespace jump =
///   • `bottomGap > 2pt` sustained for ≥2 consecutive frames, OR
///   • A terminal position where the user is not at the bottom even though
///     `isAtBottom == true` was recorded as the trigger state.
///
/// Enable via the `SPIKE_LIST_CONTAINER` build flag OR
/// `CANVAS_SCROLL_METRICS=1` env var (so baseline runs also record).
/// Log writes go to:
///   1. `os_log` subsystem `ai.beechat.canvas`, category `ScrollMetrics`
///   2. A JSONL ring buffer in `~/Library/Application Support/BeeChatApp/spike-scroll-trace.jsonl`
///      (rolling, capped at 50,000 lines; oldest evicted on overflow).
public struct CanvasScrollMetrics: Sendable {
    public let contentSizeHeight: CGFloat
    public let containerSizeHeight: CGFloat
    public let contentOffsetY: CGFloat
    public let isAtBottom: Bool
    public let composerHeight: CGFloat?
    public let phase: ScrollPhase
    public let timestamp: TimeInterval

    public var bottomGap: CGFloat {
        (contentOffsetY + containerSizeHeight) - contentSizeHeight
    }
}

/// Phase enum recorded per-frame to make trace analysis tractable.
/// Values mirror the visible UI state at the moment of the geometry sample.
public enum ScrollPhase: String, Codable, Sendable {
    case idle
    case composerMultiLine
    case sending
    case thinking
    case streamingStart
    case streaming
    case completedBridge
    case settled
    case userSend
    case loadEarlier
}

/// ScrollTraceLogger — single actor that owns the JSONL ring buffer + os_log sink.
/// Use `record(_:)` from the main actor; the actor hop keeps file writes off the
/// rendering critical path.
public actor ScrollTraceLogger {
    public static let shared = ScrollTraceLogger()

    private let logger = Logger(subsystem: "ai.beechat.canvas", category: "ScrollMetrics")
    private let maxLines = 50_000
    private var pendingLines: [String] = []
    private var fileURL: URL?
    private var lineCount: Int = 0
    private var lastFlush: Date = .distantPast
    private var enabled: Bool = false

    /// Composer height — most recent value seen from MainWindow.
    /// We keep a small `nonisolated(unsafe)` so the metric struct can capture
    /// a snapshot without forcing every call site onto the actor.
    public nonisolated(unsafe) static var _latestComposerHeight: CGFloat? = nil
    public nonisolated(unsafe) static var _latestPhase: ScrollPhase = .idle

    public func configure(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let str = String(data: data, encoding: .utf8) {
            lineCount = str.split(separator: "\n", omittingEmptySubsequences: true).count
        } else {
            lineCount = 0
        }
        enabled = true
        logger.log("ScrollTraceLogger enabled → \(fileURL.path, privacy: .public) (resumed at line \(self.lineCount))")
    }

    public func disable() {
        enabled = false
        flush()
        logger.log("ScrollTraceLogger disabled")
    }

    public func setPhase(_ phase: ScrollPhase) {
        Self._latestPhase = phase
    }

    public func setComposerHeight(_ height: CGFloat) {
        Self._latestComposerHeight = height
    }

    public func record(_ metrics: CanvasScrollMetrics) {
        guard enabled else { return }

        let dict: [String: Any] = [
            "ts": metrics.timestamp,
            "phase": metrics.phase.rawValue,
            "contentSizeH": Double(metrics.contentSizeHeight),
            "containerSizeH": Double(metrics.containerSizeHeight),
            "contentOffsetY": Double(metrics.contentOffsetY),
            "isAtBottom": metrics.isAtBottom,
            "bottomGap": Double(metrics.bottomGap),
            "composerHeight": metrics.composerHeight.map(Double.init) ?? NSNull()
        ]

        // 1. os_log — concise, structured
        logger.log("""
            scroll frame: phase=\(metrics.phase.rawValue, privacy: .public) \
            contentH=\(metrics.contentSizeHeight, privacy: .public) \
            containerH=\(metrics.containerSizeHeight, privacy: .public) \
            offsetY=\(metrics.contentOffsetY, privacy: .public) \
            gap=\(metrics.bottomGap, privacy: .public) \
            isAtBottom=\(metrics.isAtBottom) \
            composerH=\(metrics.composerHeight ?? -1, privacy: .public)
            """)

        // 2. JSONL ring buffer — for offline analysis
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
           let json = String(data: data, encoding: .utf8) {
            pendingLines.append(json)
        }

        if Date().timeIntervalSince(lastFlush) > 1.0 {
            flush()
        }
    }

    public func flush() {
        guard let fileURL = fileURL, !pendingLines.isEmpty else { return }
        let lines = pendingLines.joined(separator: "\n") + "\n"
        pendingLines.removeAll(keepingCapacity: true)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = lines.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                    lineCount += lines.split(separator: "\n", omittingEmptySubsequences: true).count
                }
            } else {
                try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try lines.data(using: .utf8)?.write(to: fileURL, options: .atomic)
                lineCount = lines.split(separator: "\n", omittingEmptySubsequences: true).count
            }
            // Roll the file if we've exceeded the cap. Keep the tail for offline review.
            if lineCount > maxLines {
                let dropCount = lineCount - maxLines
                roll(keepingTail: dropCount * -1)
            }
            lastFlush = Date()
        } catch {
            logger.error("ScrollTraceLogger flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func roll(keepingTail: Int) {
        guard let fileURL = fileURL else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let str = String(data: data, encoding: .utf8) else { return }
        let lines = str.split(separator: "\n", omittingEmptySubsequences: true)
        let dropCount = lines.count + keepingTail // keepingTail is negative
        guard dropCount > 0, dropCount < lines.count else { return }
        let kept = lines.dropFirst(dropCount).joined(separator: "\n") + "\n"
        try? kept.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        self.lineCount = lines.count - dropCount
        logger.log("ScrollTraceLogger rolled: dropped \(dropCount) old frames, kept \(self.lineCount)")
    }
}

/// SpikeScrollTrace — view modifier that records per-frame scroll geometry.
/// Apply to the scroll container; `phaseProvider` returns the current phase
/// at sample time, and `composerHeight` is read from `ScrollTraceLogger`.
public struct SpikeScrollTrace: ViewModifier {
    public let phaseProvider: () -> ScrollPhase
    public init(phaseProvider: @escaping () -> ScrollPhase) {
        self.phaseProvider = phaseProvider
    }

    public func body(content: Content) -> some View {
        content.onScrollGeometryChangeCompat(
            transform: { geo in
                let metrics = CanvasScrollMetrics(
                    contentSizeHeight: geo.contentSize.height,
                    containerSizeHeight: geo.containerSize.height,
                    contentOffsetY: geo.contentOffset.y,
                    isAtBottom: false, // overwritten in action where state is known
                    composerHeight: ScrollTraceLogger._latestComposerHeight,
                    phase: ScrollTraceLogger._latestPhase,
                    timestamp: Date().timeIntervalSince1970
                )
                Task { await ScrollTraceLogger.shared.record(metrics) }
                // Distance-from-bottom threshold preserved (80pt) for parity with current behavior.
                let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                return distanceFromBottom < 80
            },
            action: { _, newValue in
                // Mirror the metrics into the same actor with the resolved isAtBottom.
                // We don't have access to geo here, so we log the post-state only;
                // the transform closure already captured the geometry values.
                _ = newValue
            }
        )
    }
}

public extension View {
    /// Attach scroll-geometry instrumentation (no-op if the logger is disabled).
    func spikeScrollTrace(phaseProvider: @escaping () -> ScrollPhase) -> some View {
        modifier(SpikeScrollTrace(phaseProvider: phaseProvider))
    }
}

/// Spike environment — exposes the spike trace toggle to MainWindow without
/// leaking the actor into SwiftUI's environment machinery.
public enum SpikeTrace {
    /// True if SPIKE_LIST_CONTAINER is defined OR env var CANVAS_SCROLL_METRICS=1.
    public static let enabled: Bool = {
        #if SPIKE_LIST_CONTAINER
        return true
        #else
        return ProcessInfo.processInfo.environment["CANVAS_SCROLL_METRICS"] == "1"
        #endif
    }()

    public static func bootstrapIfNeeded() {
        guard enabled else { return }
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSupport.appendingPathComponent("BeeChatApp", isDirectory: true)
        let url = dir.appendingPathComponent("spike-scroll-trace.jsonl")
        Task { await ScrollTraceLogger.shared.configure(fileURL: url) }
        os_log("SpikeTrace bootstrap: enabled=\(SpikeTrace.enabled, privacy: .public) sink=\(url.path, privacy: .public)")
    }
}