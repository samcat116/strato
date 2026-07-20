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
        // mTLS artifact downloads: URLSession cannot present a NIOSSL client
        // certificate, so image/update fetches from the control plane's SPIFFE
        // listener go through AsyncHTTPClient with the SVID-backed TLS config.
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.16.0"),
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
        // SwiftOVN: Linux only at build time (OVN/OVS not available on macOS), but the
        // dependency is declared unconditionally so the package graph — and therefore
        // Package.resolved — is identical on every host. Linking is gated per-target
        // below with `.when(platforms:)`. Revision-pinned (not branch) so `swift package
        // update` on macOS can't silently move the pin. Bump by editing this revision.
        .package(
            url: "https://github.com/samcat116/swift-ovn.git",
            revision: "d474198c454b87b62d6af68fa15241e8d1ed9bd5"),
    ],
    targets: [
        // Core library with testable code (no SwiftQEMU dependency)
        .target(
            name: "StratoAgentCore",
            dependencies: [
                .product(name: "StratoShared", package: "shared"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Toml", package: "swift-toml"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                // Streams download bodies to disk off the cooperative pool.
                // NonBlockingFileIO is deprecated in favor of this.
                .product(name: "_NIOFileSystem", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
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
                // SwiftQEMU: both Linux (KVM) and macOS (HVF).
                .product(name: "SwiftQEMU", package: "swift-qemu"),
                // Linux-only backends. Declared here for every host so the package graph
                // stays identical, but only linked and compiled on Linux. Source imports
                // are guarded with `#if os(Linux)`.
                .product(
                    name: "SwiftOVN", package: "swift-ovn",
                    condition: .when(platforms: [.linux])),
                .product(
                    name: "SwiftFirecracker", package: "SwiftFirecracker",
                    condition: .when(platforms: [.linux])),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StratoAgentTests",
            dependencies: [
                "StratoAgentCore",
                "StratoAgentSPIFFE",
                .product(name: "StratoShared", package: "shared"),
                // A loopback HTTP origin for the artifact-downloader tests.
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
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
