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
        // SwiftQEMU for QEMU integration
        .package(url: "https://github.com/samcat116/swift-qemu", branch: "main"),
        // 🔵 Non-blocking, event-driven networking for Swift
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // 🗄 ArgumentParser for CLI
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        // 📝 Logging
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // 🌐 OVN/OVS networking integration
        .package(url: "https://github.com/samcat116/swift-ovn.git", branch: "main"),
        // ⚙️ TOML configuration parsing
        .package(url: "https://github.com/samcat116/swift-toml.git", branch: "master"),
    ],
    targets: [
        .executableTarget(
            name: "StratoAgent",
            dependencies: [
                .product(name: "StratoShared", package: "shared"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Toml", package: "swift-toml"),
            ] + qemuAndNetworkDependencies,
            swiftSettings: swiftSettings
        )
    ],
    swiftLanguageModes: [.v5]
)

var swiftSettings: [SwiftSetting] {
    // Minimal settings for Swift 6 compatibility
    []
}

// Conditional dependencies for Linux only (QEMU/KVM and OVN/OVS require Linux)
#if os(Linux)
var qemuAndNetworkDependencies: [Target.Dependency] {
    [
        .product(name: "SwiftQEMU", package: "swift-qemu"),
        .product(name: "SwiftOVN", package: "swift-ovn"),
    ]
}
#else
var qemuAndNetworkDependencies: [Target.Dependency] {
    // Empty array for macOS development - mock implementations are used instead
    []
}
#endif
