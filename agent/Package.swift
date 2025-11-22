// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "strato-agent",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // StratoShared for common models and protocols
        .package(path: "../shared"),
        .package(url: "https://github.com/samcat116/swift-qemu", branch: "main"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/samcat116/swift-ovn.git", branch: "main"),
        .package(url: "https://github.com/samcat116/swift-toml.git", branch: "master"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        // Core library with testable code (no SwiftQEMU dependency)
        .target(
            name: "StratoAgentCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Toml", package: "swift-toml"),
            ],
            path: "Sources/StratoAgentCore",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "StratoAgent",
            dependencies: [
                "StratoAgentCore",
                .product(name: "StratoShared", package: "shared"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ] + qemuAndNetworkDependencies,
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StratoAgentTests",
            dependencies: [
                "StratoAgentCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            swiftSettings: swiftSettings
        )
    ],
    swiftLanguageModes: [.v5]
)

var swiftSettings: [SwiftSetting] {
    []
}

// Conditional dependencies based on platform
// SwiftQEMU: Available on both Linux (KVM) and macOS (HVF)
// SwiftOVN: Linux only (OVN/OVS not available on macOS)
#if os(Linux)
var qemuAndNetworkDependencies: [Target.Dependency] {
    [
        .product(name: "SwiftQEMU", package: "swift-qemu"),
        .product(name: "SwiftOVN", package: "swift-ovn"),
    ]
}
#else
var qemuAndNetworkDependencies: [Target.Dependency] {
    // macOS: SwiftQEMU with HVF support, user-mode networking (no OVN/OVS)
    [
        .product(name: "SwiftQEMU", package: "swift-qemu"),
    ]
}
#endif
