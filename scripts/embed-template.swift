#!/usr/bin/env swift
// swift-tools-version:5.9
// scripts/embed-template.swift
//
// Regenerates the `embeddedTemplate` Swift string literal from a Resources/*.html
// source file. The template pattern (resource bundle → flat Bundle.main →
// embedded constant) requires the constant to be in sync with the .html file
// or hand-assembled app bundles will diverge.
//
// Usage:
//   swift scripts/embed-template.swift                      # default: MessageTemplate
//   swift scripts/embed-template.swift TranscriptTemplate   # regenerate transcript template
//   swift scripts/embed-template.swift --check             # exit 0 if in sync, 1 otherwise (CI gate)
//   swift scripts/embed-template.swift --check TranscriptTemplate
//
// WP-2 deliverable §3.1 (single-webview-transcript-plan.md).

import Foundation

// MARK: - Config

struct TemplateConfig {
    let name: String           // e.g. "MessageTemplate"
    let resourcePath: String   // e.g. "Sources/App/Resources/MessageTemplate.html"
    let swiftPath: String      // e.g. "Sources/App/Rendering/MessageTemplate.swift"
    let markerStart: String    // start marker comment for the embedded constant
    let markerEnd: String      // end marker comment
}

let configs: [TemplateConfig] = [
    TemplateConfig(
        name: "MessageTemplate",
        resourcePath: "Sources/App/Resources/MessageTemplate.html",
        swiftPath: "Sources/App/Rendering/MessageTemplate.swift",
        markerStart: "private static let embeddedTemplate = \"\"\"",
        markerEnd: "\"\"\""
    ),
    TemplateConfig(
        name: "TranscriptTemplate",
        resourcePath: "Sources/App/Resources/TranscriptTemplate.html",
        swiftPath: "Sources/App/Rendering/TranscriptTemplate.swift",
        markerStart: "private static let embeddedTemplate = \"\"\"",
        markerEnd: "\"\"\""
    ),
]

// MARK: - CLI

var args = CommandLine.arguments
let checkMode = args.contains("--check")
if checkMode {
    args.removeAll { $0 == "--check" }
}

let requestedName: String
if args.count > 1 {
    requestedName = args[1]
} else {
    requestedName = "MessageTemplate"
}

guard let config = configs.first(where: { $0.name == requestedName }) else {
    FileHandle.standardError.write(
        Data("error: unknown template '\(requestedName)'. Known: \(configs.map(\.name).joined(separator: ", "))\n".utf8)
    )
    exit(2)
}

// MARK: - Read source

guard FileManager.default.fileExists(atPath: config.resourcePath) else {
    FileHandle.standardError.write(
        Data("error: source file not found at \(config.resourcePath)\n".utf8)
    )
    exit(2)
}

let rawHtml = try String(contentsOfFile: config.resourcePath, encoding: .utf8)

// MARK: - Escape for Swift string literal

/// Escape the raw HTML so it can sit inside a Swift """ multi-line string.
/// Strategy: escape backslashes first (so subsequent \u replacements don't
/// double-escape), then escape the two sequences that would otherwise close
/// the literal early (\""" sequences and lone """). Everything else is fine
/// in a raw triple-quoted literal — Swift only interprets """ / \"\"\" / \\.
func escapeForSwiftTripleQuoted(_ s: String) -> String {
    var out = s
    out = out.replacingOccurrences(of: "\\", with: "\\\\")
    // The escape sequence \"\"\" would prematurely close a triple-quoted literal.
    // We don't expect backslash-quote-quote-quote in normal HTML, but be safe.
    out = out.replacingOccurrences(of: "\\\"\\\"\\\"", with: "\\\\\\\"\\\\\\\"\\\\\\\"")
    return out
}

let escaped = escapeForSwiftTripleQuoted(rawHtml)

// MARK: - Generate replacement block

/// Replace the embedded template constant body in the Swift file. We look for
/// the `markerStart` line and rewrite from there through the next `markerEnd`.
/// This is intentionally narrow — touching only the embedded constant, never
/// the resolution-chain logic above it (which is hand-written and stable).
func generateReplacement(original: String, escaped: String, config: TemplateConfig) -> String {
    guard let startRange = original.range(of: config.markerStart) else {
        return ""  // sentinel — caller treats empty string as "not found"
    }
    // Find the FIRST markerEnd AFTER the markerStart (the body may itself contain
    // """-looking sequences after escaping, but those are now \\"\\"\\" and won't
    // match the literal markerEnd). Searching from startRange.upperBound avoids
    // any earlier occurrences in doc comments.
    let afterStart = startRange.upperBound
    guard let endOffset = original.range(of: config.markerEnd, range: afterStart..<original.endIndex) else {
        return ""
    }
    let before = String(original[..<startRange.lowerBound])
    let after = String(original[endOffset.upperBound...])
    return before + config.markerStart + "\n" + escaped + "\n" + config.markerEnd + after
}

guard FileManager.default.fileExists(atPath: config.swiftPath) else {
    FileHandle.standardError.write(
        Data("error: Swift file not found at \(config.swiftPath)\n".utf8)
    )
    exit(2)
}

let originalSwift = try String(contentsOfFile: config.swiftPath, encoding: .utf8)
let newSwift = generateReplacement(original: originalSwift, escaped: escaped, config: config)
guard !newSwift.isEmpty else {
    FileHandle.standardError.write(
        Data("error: could not find embedded template markers in \(config.swiftPath)\n".utf8)
    )
    exit(2)
}

// MARK: - Check vs write

if checkMode {
    // --check: exit 0 if the Swift file already has the up-to-date embedded constant.
    // We compare byte-for-byte. We deliberately do NOT trim whitespace differences —
    // if the embedded literal drifted, surface it so the operator regenerates.
    if originalSwift == newSwift {
        print("ok: \(config.name) embedded constant is in sync with \(config.resourcePath)")
        exit(0)
    } else {
        let msg = "error: \(config.name) embedded constant is OUT OF SYNC with \(config.resourcePath)\n" +
                  "       Run: swift scripts/embed-template.swift \(config.name)\n"
        FileHandle.standardError.write(Data(msg.utf8))
        exit(1)
    }
} else {
    // Write mode — back up, overwrite, report.
    let backupPath = config.swiftPath + ".bak"
    try? FileManager.default.removeItem(atPath: backupPath)
    try? FileManager.default.copyItem(atPath: config.swiftPath, toPath: backupPath)
    try newSwift.write(toFile: config.swiftPath, atomically: true, encoding: .utf8)
    print("ok: regenerated \(config.swiftPath) from \(config.resourcePath)")
    print("    backup at \(backupPath)")
    print("    embedded constant: \(escaped.count) bytes")
    exit(0)
}
