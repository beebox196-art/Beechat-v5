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
        .testTarget(
            name: "BeeChatPersistenceTests",
            dependencies: ["BeeChatPersistence"],
            path: "Tests/BeeChatPersistenceTests"),
    ]
)
