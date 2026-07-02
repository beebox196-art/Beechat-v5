// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "W4MemoryProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/tomdai/markdown-webview", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "W4MemoryProbe",
            dependencies: [
                .product(name: "MarkdownWebView", package: "markdown-webview"),
            ]
        ),
    ]
)
