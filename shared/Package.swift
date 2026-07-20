// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "StratoShared",
    platforms: [
        .macOS(.v14),
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "StratoShared",
            targets: ["StratoShared"]
        ),
        .library(
            name: "SPIFFEVerification",
            targets: ["SPIFFEVerification"]
        ),
    ],
    dependencies: [
        // Foundation only - minimal dependencies for shared code
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // SPIFFEVerification only (StratoShared itself stays dependency-light)
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "StratoShared",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        // SPIFFE peer-identity verification shared by the control plane (its
        // SPIRE server admin client) and the agent (its control-plane socket).
        // A separate target so StratoShared consumers don't inherit NIOSSL and
        // swift-certificates.
        .target(
            name: "SPIFFEVerification",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "StratoSharedTests",
            dependencies: ["StratoShared"],
            swiftSettings: [
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)