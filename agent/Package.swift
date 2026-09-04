// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "strato-agent",
    platforms: [
        // macOS 15+ required by grpc-swift-2 (the macOS agent is dev/test only)
        .macOS(.v15)
    ],
    products: [
        .executable(name: "StratoAgent", targets: ["StratoAgent"]),
        .library(name: "StratoAgentRuntime", targets: ["StratoAgentRuntime"]),
    ],
    dependencies: [
        // StratoShared for common models and protocols
        .package(path: "../shared"),
        // SwiftFirecracker for Firecracker microVM support (Linux only)
        .package(path: "../SwiftFirecracker"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // 2.37.1+ leads its default TLS group list with X25519MLKEM768, so the
        // agent's outbound mTLS negotiates hybrid post-quantum key exchange
        // wherever the peer supports it. Do not lower this floor.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.1"),
        // mTLS artifact downloads: URLSession cannot present a NIOSSL client
        // certificate, so image/update fetches from the control plane's SPIFFE
        // listener go through AsyncHTTPClient with the SVID-backed TLS config.
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.16.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.2.0"),
        .package(
            url: "https://github.com/samcat116/swift-toml.git",
            revision: "10094db34a4eade03c0fc0b1a60ea90df76af93e"),
        // SPIFFE Workload API (gRPC over Unix domain socket)
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        // X.509 parsing (SVID expiry, DER -> PEM conversion). Keep the floor in
        // lockstep with shared/ and control-plane/: all three verify SPIFFE SVID
        // chains, and a stale floor here silently resolved to 1.15.1 while the
        // other two were on 1.19.x.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.4"),
        // SwiftOVN: Linux only at build time (OVN/OVS not available on macOS), but the
        // dependency is declared unconditionally so the package graph — and therefore
        // Package.resolved — is identical on every host. Linking is gated per-target
        // below with `.when(platforms:)`. Revision-pinned (not branch) so `swift package
        // update` on macOS can't silently move the pin. Bump by editing this revision.
        //
        // Keep SwiftOVN's default traits: its `TLS` trait is what makes
        // `OVSDBEndpoint.ssl` available, and NetworkServiceLinux matches on that
        // case to attach the northbound mTLS material. Passing `traits: []` here
        // (or building with `--disable-default-traits`) turns that case
        // unavailable and breaks the build.
        .package(
            url: "https://github.com/samcat116/swift-ovn.git",
            revision: "e53651361eb3bd7e9a0de1f08e3ad9fd13f3341a"),
        // swift-libvirt: the RPC client `LibvirtService` drives VMs through
        // (issue #902). Unlike SwiftOVN and SwiftFirecracker this needs no
        // `.when(platforms:)` condition anywhere — it speaks libvirt's wire
        // protocol over NIO rather than linking libvirt's C library, so it has
        // no system dependency, and its `.macOS(.v15)` floor matches this
        // package's exactly. Only the *registration* is platform-gated.
        //
        // 0.1.1 is a floor, not a preference (STR-190): before it, XDR `char`
        // and `unsigned char` were decoded as byte strings rather than as the
        // four-byte scalars they are, so `domainGetInfo` never decoded at all —
        // host reservations read zero and every resize failed.
        //
        // `.upToNextMinor` rather than `from:`, which SwiftPM reads as
        // `.upToNextMajor` with no special case for `0.x` — so `from: "0.1.1"`
        // would let a `swift package update` take `0.2.0` unattended, from the
        // very upstream whose pre-1.0 decoding just changed shape under us. A
        // minor bump here should be somebody's decision.
        .package(
            url: "https://github.com/samcat116/swift-libvirt.git", .upToNextMinor(from: "0.1.1")),
    ],
    targets: [
        // Small, dependency-light values shared by the agent's domain,
        // networking, storage, and runtime layers.
        .target(
            name: "StratoAgentKit",
            dependencies: [
                .product(name: "StratoShared", package: "shared"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/StratoAgentKit",
            swiftSettings: swiftSettings
        ),
        // Pure libvirt domain planning and XML transformations. This is the
        // first leaf extracted from Core's otherwise mostly acyclic clusters.
        .target(
            name: "StratoAgentDomainXML",
            dependencies: [
                "StratoAgentKit",
                .product(name: "StratoShared", package: "shared"),
                .product(name: "Libvirt", package: "swift-libvirt"),
            ],
            path: "Sources/StratoAgentDomainXML",
            swiftSettings: swiftSettings
        ),
        // Core library with testable code (no native-library dependencies)
        .target(
            name: "StratoAgentCore",
            dependencies: [
                "StratoAgentKit",
                "StratoAgentDomainXML",
                .product(name: "StratoShared", package: "shared"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Toml", package: "swift-toml"),
                .product(name: "TomlConfiguration", package: "swift-toml"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                // The guest-facing instance metadata listener (STR-56) — the
                // one HTTP *server* in the agent. All three are already in the
                // resolved graph (NIOPosix via AsyncHTTPClient, NIOHTTP1 via
                // StratoAgentSPIFFE, NIOConcurrencyHelpers via NIOPosix), so
                // declaring them here does not move Package.resolved.
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                // Streams download bodies to disk off the cooperative pool.
                // NonBlockingFileIO is deprecated in favor of this.
                .product(name: "_NIOFileSystem", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                // The libvirt driver's *pure* layer lives here — domain-state
                // mapping, error translation, memory-stat parsing — for the
                // reason DomainXMLBuilder gives: the driver itself links a
                // hypervisor SDK and has no unit tests, so anything that can be
                // decided without a daemon is decided (and asserted) in here.
                // Linking the SDK in the core target costs nothing, since
                // swift-libvirt is pure Swift with no system dependency.
                .product(name: "Libvirt", package: "swift-libvirt"),
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
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SPIFFEVerification", package: "shared"),
                .product(name: "SPIFFEKit", package: "shared"),
                .product(name: "StratoShared", package: "shared"),
            ],
            path: "Sources/StratoAgentSPIFFE",
            exclude: ["Generated/README.md", "Generated/proto"],
            swiftSettings: swiftSettings
        ),
        // Runtime library containing the agent actor and all platform drivers.
        // Keeping process startup in a separate executable target makes this
        // implementation directly importable by focused runtime tests.
        .target(
            name: "StratoAgentRuntime",
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
                // libvirt RPC client backing `LibvirtService` (issue #902).
                .product(name: "Libvirt", package: "swift-libvirt"),
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
            path: "Sources/StratoAgentRuntime",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "StratoAgent",
            dependencies: [
                "StratoAgentRuntime",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/StratoAgent",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StratoAgentSPIFFETests",
            dependencies: [
                "StratoAgentSPIFFE",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "StratoAgentTestSupport",
            path: "Tests/StratoAgentTestSupport",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StratoAgentTests",
            dependencies: [
                "StratoAgentCore",
                "StratoAgentDomainXML",
                "StratoAgentTestSupport",
                .product(name: "StratoShared", package: "shared"),
                .product(name: "InMemoryLogging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Libvirt", package: "swift-libvirt"),
            ],
            // Golden documents are read from the source tree via #filePath,
            // not from a resource bundle, so SwiftPM leaves them alone.
            exclude: ["Goldens"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StratoAgentStorageTests",
            dependencies: [
                "StratoAgentCore",
                "StratoAgentTestSupport",
                .product(name: "StratoShared", package: "shared"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StratoAgentPlatformTests",
            dependencies: [
                "StratoAgentCore",
                "StratoAgentTestSupport",
                .product(name: "StratoShared", package: "shared"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StratoAgentRuntimeTests",
            dependencies: [
                "StratoAgentRuntime",
                "StratoAgentCore",
                .product(name: "StratoShared", package: "shared"),
                .product(name: "Logging", package: "swift-log"),
                .product(
                    name: "SwiftFirecracker", package: "SwiftFirecracker",
                    condition: .when(platforms: [.linux])),
            ],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    ]
}
