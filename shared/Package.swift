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
        // Both NIO packages serve SPIFFEVerification only — StratoShared
        // itself stays Foundation-only. swift-nio-ssl 2.37.1+ leads its
        // default TLS group list with X25519MLKEM768, giving hybrid
        // post-quantum key exchange; do not lower that floor.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.1"),
        // Keep in lockstep with agent/ and control-plane/ — all three verify
        // SPIFFE SVID chains through this package.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.4"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
    ],
    targets: [
        .target(
            name: "StratoShared",
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
