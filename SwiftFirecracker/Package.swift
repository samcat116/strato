// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SwiftFirecracker",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SwiftFirecracker",
            targets: ["SwiftFirecracker"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "CLinuxPidfd",
            path: "Sources/CLinuxPidfd",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SwiftFirecracker",
            dependencies: [
                "CLinuxPidfd",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "SwiftFirecrackerTests",
            dependencies: [
                "SwiftFirecracker",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                // EmbeddedChannel, for driving the line framer without a socket.
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ]
)
