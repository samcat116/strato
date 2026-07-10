// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "strato-agent",
    platforms: [
        // macOS 15+ required by grpc-swift-2 (the macOS agent is dev/test only)
        .macOS(.v15)
    ],
    dependencies: [
        // StratoShared for common models and protocols
        .package(path: "../shared"),
        // SwiftFirecracker for Firecracker microVM support (Linux only)
        .package(path: "../SwiftFirecracker"),
        .package(url: "https://github.com/samcat116/swift-qemu", branch: "main"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/samcat116/swift-toml.git", branch: "master"),
        // SPIFFE Workload API (gRPC over Unix domain socket)
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        // X.509 parsing (SVID expiry, DER -> PEM conversion)
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
    ] + platformPackageDependencies,
    targets: [
        // Core library with testable code (no SwiftQEMU dependency)
        .target(
            name: "StratoAgentCore",
            dependencies: [
                .product(name: "StratoShared", package: "shared"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Toml", package: "swift-toml"),
            ],
            path: "Sources/StratoAgentCore",
            swiftSettings: swiftSettings
        ),
        // SPIFFE/SPIRE support: SVID types, TLS config, file- and Workload-API-based
        // clients. A separate library target so tests can import it (the executable
        // target cannot be imported by the test target).
        .target(
            name: "StratoAgentSPIFFE",
            dependencies: [
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            path: "Sources/StratoAgentSPIFFE",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "StratoAgent",
            dependencies: [
                "StratoAgentCore",
                "StratoAgentSPIFFE",
                .product(name: "StratoShared", package: "shared"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
            ] + qemuAndNetworkDependencies,
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StratoAgentTests",
            dependencies: [
                "StratoAgentCore",
                "StratoAgentSPIFFE",
                .product(name: "StratoShared", package: "shared"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        )
    ],
    swiftLanguageModes: [.v6]
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    ]
}

// Conditional dependencies based on platform
// SwiftQEMU: Available on both Linux (KVM) and macOS (HVF)
// SwiftOVN: Linux only (OVN/OVS not available on macOS)
#if os(Linux)
var platformPackageDependencies: [Package.Dependency] {
    // Revision-pinned (not branch) so `swift package update` on macOS can't
    // silently move the pin. Bump by editing this revision.
    [
        .package(
            url: "https://github.com/samcat116/swift-ovn.git",
            revision: "d474198c454b87b62d6af68fa15241e8d1ed9bd5")
    ]
}
var qemuAndNetworkDependencies: [Target.Dependency] {
    [
        .product(name: "SwiftQEMU", package: "swift-qemu"),
        .product(name: "SwiftOVN", package: "swift-ovn"),
        .product(name: "SwiftFirecracker", package: "SwiftFirecracker"),
    ]
}
#else
var platformPackageDependencies: [Package.Dependency] {
    []
}
var qemuAndNetworkDependencies: [Target.Dependency] {
    // macOS: SwiftQEMU with HVF support, user-mode networking (no OVN/OVS)
    [
        .product(name: "SwiftQEMU", package: "swift-qemu"),
    ]
}
#endif
