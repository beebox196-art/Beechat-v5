// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BeeChatPersistence",
    platforms: [
        // Single-user app, single deployment target: Adam's Mac mini.
        // Targeting an older floor was speculative generality — it constrained the
        // WebKit feature set available to the transcript document (Safari 17) for no
        // deployment we actually have. See Docs/Specs/Active/option-b-prior-art-register.md §1.
        // iOS floor left at v17 pending decision D4 (BeeChat-Mobile platform target).
        .macOS(.v26),
        .iOS(.v17)
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
        .library(
            name: "BeeBoard",
            targets: ["BeeBoard"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/apple/swift-cmark", branch: "gfm"),
        .package(path: "Vendors/ChatField"),
    ],
    targets: [
        .target(
            name: "BeeChatPersistence",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/BeeChatPersistence",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "BeeChatGateway",
            path: "Sources/BeeChatGateway",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "BeeChatSyncBridge",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .target(name: "BeeChatPersistence"),
                .target(name: "BeeChatGateway"),
            ],
            path: "Sources/BeeChatSyncBridge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "BeeBoard",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .target(name: "BeeChatPersistence"),
            ],
            path: "Sources/BeeBoard",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BeeChatPersistenceTests",
            dependencies: ["BeeChatPersistence"],
            path: "Tests/BeeChatPersistenceTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BeeChatGatewayTests",
            dependencies: ["BeeChatGateway"],
            path: "Tests/BeeChatGatewayTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BeeChatSyncBridgeTests",
            dependencies: ["BeeChatSyncBridge", "BeeChatPersistence", "BeeChatGateway"],
            path: "Tests/BeeChatSyncBridgeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BeeChatIntegrationTest",
            dependencies: [
                .target(name: "BeeChatPersistence"),
                .target(name: "BeeChatGateway"),
                .target(name: "BeeChatSyncBridge"),
            ],
            path: "Sources/BeeChatIntegrationTest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BeeChatApp",
            dependencies: [
                .target(name: "BeeChatPersistence"),
                .target(name: "BeeChatGateway"),
                .target(name: "BeeChatSyncBridge"),
                .target(name: "BeeBoard"),
                .product(name: "ChatField", package: "ChatField"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            path: "Sources/App",
            resources: [
                .process("Assets.xcassets"),
                .process("Resources"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BeeChatAppTests",
            dependencies: ["BeeChatApp"],
            path: "Tests/BeeChatAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
