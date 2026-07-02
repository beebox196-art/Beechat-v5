// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BeeChatPersistence",
    platforms: [
        .macOS(.v14),
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
        .package(path: "Vendors/ChatField"),
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
        .target(
            name: "BeeBoard",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .target(name: "BeeChatPersistence"),
            ],
            path: "Sources/BeeBoard",
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
                .target(name: "BeeBoard"),
                .product(name: "ChatField", package: "ChatField"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources/App",
            resources: [
                .process("Assets.xcassets"),
                .process("Resources"),
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
