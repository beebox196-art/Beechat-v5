// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BeeChatPersistence",
    platforms: [
        .macOS(.v14)
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
    ],
    targets: [
        .target(
            name: "BeeChatPersistence",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/BeeChatPersistence"),
        .target(
            name: "BeeChatGateway",
            path: "Sources/BeeChatGateway"),
        .target(
            name: "BeeChatSyncBridge",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .target(name: "BeeChatPersistence"),
                .target(name: "BeeChatGateway"),
            ],
            path: "Sources/BeeChatSyncBridge"),
        .testTarget(
            name: "BeeChatPersistenceTests",
            dependencies: ["BeeChatPersistence"],
            path: "Tests/BeeChatPersistenceTests"),
        .testTarget(
            name: "BeeChatGatewayTests",
            dependencies: ["BeeChatGateway"],
            path: "Tests/BeeChatGatewayTests"),
        .testTarget(
            name: "BeeChatSyncBridgeTests",
            dependencies: ["BeeChatSyncBridge", "BeeChatPersistence", "BeeChatGateway"],
            path: "Tests/BeeChatSyncBridgeTests"),
    ]
)
