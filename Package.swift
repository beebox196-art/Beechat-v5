// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BeeChatPersistence",
    platforms: [
        // SP-001: bumped from .v14 to .v15 to use ScrollPosition +
        // .scrollPosition(_:anchor:) + 2-arg .defaultScrollAnchor(_:for:).
        // These APIs are macOS 15+ only, which requires
        // swift-tools-version: 6.0. Adam's machine is macOS 26.
        // (iOS line omitted — BeeChat is macOS-only; the original
        // b463eb0 added .iOS(.v18) which is out of scope for this PR.)
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "BeeChatPersistence",
            targets: ["BeeChatPersistence"]),
        .library(
            name: "BeeChatGateway",
            targets: ["BeeChatGateway"]),
        .library(
            name: "BeeChatSyncBridge",
            targets: ["BeeChatSyncBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/kevinhermawan/ChatField", from: "3.0.4"),
    ],
    targets: [
        .target(
            name: "BeeChatPersistence",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/BeeChatPersistence",
            swiftSettings: [.swiftLanguageVersion(.v5)]
        ),
        .target(
            name: "BeeChatGateway",
            path: "Sources/BeeChatGateway",
            swiftSettings: [.swiftLanguageVersion(.v5)]
        ),
        .target(
            name: "BeeChatSyncBridge",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .target(name: "BeeChatPersistence"),
                .target(name: "BeeChatGateway"),
            ],
            path: "Sources/BeeChatSyncBridge",
            swiftSettings: [.swiftLanguageVersion(.v5)]
        ),
        .testTarget(
            name: "BeeChatPersistenceTests",
            dependencies: ["BeeChatPersistence"],
            path: "Tests/BeeChatPersistenceTests",
            swiftSettings: [.swiftLanguageVersion(.v5)]
        ),
        .testTarget(
            name: "BeeChatGatewayTests",
            dependencies: ["BeeChatGateway"],
            path: "Tests/BeeChatGatewayTests",
            swiftSettings: [.swiftLanguageVersion(.v5)]
        ),
        .testTarget(
            name: "BeeChatSyncBridgeTests",
            dependencies: ["BeeChatSyncBridge", "BeeChatPersistence", "BeeChatGateway"],
            path: "Tests/BeeChatSyncBridgeTests",
            swiftSettings: [.swiftLanguageVersion(.v5)]
        ),
        .executableTarget(
            name: "BeeChatIntegrationTest",
            dependencies: [
                .target(name: "BeeChatPersistence"),
                .target(name: "BeeChatGateway"),
                .target(name: "BeeChatSyncBridge"),
            ],
            path: "Sources/BeeChatIntegrationTest",
            swiftSettings: [.swiftLanguageVersion(.v5)]
        ),
        .executableTarget(
            name: "BeeChatApp",
            dependencies: [
                .target(name: "BeeChatPersistence"),
                .target(name: "BeeChatGateway"),
                .target(name: "BeeChatSyncBridge"),
                .product(name: "ChatField", package: "ChatField"),
            ],
            path: "Sources/App",
            resources: [
                .process("Assets.xcassets"),
            ],
            swiftSettings: [.swiftLanguageVersion(.v5)]
        ),
        .testTarget(
            name: "BeeChatAppTests",
            dependencies: ["BeeChatApp"],
            path: "Tests/BeeChatAppTests",
            swiftSettings: [.swiftLanguageVersion(.v5)]
        ),
    ]
)
