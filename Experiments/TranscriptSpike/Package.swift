// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TranscriptSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        // markdown-webview gives us a known-good WKWebView host for one bubble.
        // The spike's own transcript document is loaded as HTML via WKWebView.loadHTMLString,
        // so the dependency is mainly for parity reference; we don't render via MarkdownWebView.
        .package(url: "https://github.com/tomdai/markdown-webview", branch: "main"),
        // GRDB is used for the spike's read-only access to the BeeChat persistence store.
        // The product name matches the upstream package; version pinned to the same floor the
        // BeeChat-v5 main package uses (>=7.0.0) so behaviour is consistent with production.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "TranscriptSpike",
            dependencies: [
                .product(name: "MarkdownWebView", package: "markdown-webview"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)