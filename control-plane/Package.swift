// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "strato",
    platforms: [
        // macOS 15+ required by grpc-swift-2 (SPIRE server API client);
        // production runs on Linux, so this only affects local dev builds.
        .macOS(.v15)
    ],
    dependencies: [
        // StratoShared for common models and protocols
        .package(path: "../shared"),
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.0"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        // 🐘 Fluent driver for Postgres.
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.12.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
        // 🔐 WebAuthn/Passkey authentication
        .package(url: "https://github.com/swift-server/webauthn-swift.git", branch: "main"),
        .package(url: "https://github.com/samcat116/swift-scim.git", branch: "main"),
        // 🔐 JWT token handling and HTTP client functionality
        .package(url: "https://github.com/vapor/jwt.git", from: "5.1.0"),
        // 📡 Shared Signals Framework receiver (SSF/CAEP/RISC security events,
        // issue #38). No tagged releases yet, so pin by revision.
        .package(
            url: "https://github.com/samcat116/swift-ssf.git",
            revision: "42159e7aaa133a0c7269ca808687a22d8cbca354"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
        // 🔐 Swift Crypto for cryptographic operations
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        // X.509 parsing and chain verification (SPIFFE SVID validation)
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        // OpenAPI generator and Vapor bindings (spec-first)
        .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-vapor.git", from: "1.0.0"),
        // 📊 OpenTelemetry observability (metrics, logging, tracing)
        .package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.0.0"),
        // 📈 swift-metrics facade (backed by swift-otel when OTEL_METRICS_ENABLED)
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.0.0"),
        // 🔴 Valkey client (coordination, rate limiting, sessions)
        .package(url: "https://github.com/valkey-io/valkey-swift.git", from: "1.4.0"),
        // SPIRE Server registration API (gRPC over Unix socket / loopback TCP)
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // TLS primitives for the SPIRE server mTLS verification callback
        // (already in the graph transitively via grpc-swift-nio-transport)
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        // ☁️ S3-compatible object storage for images (IMAGE_STORAGE_BACKEND=s3).
        // Any S3 API implementation works — AWS, MinIO, Garage, R2, Ceph RGW —
        // via IMAGE_S3_ENDPOINT; we don't bundle a service.
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0"),
        // 🌲 Cedar policy engine (IAM phases 3-5): Swift wrapper over the
        // cedar-policy crate, shipping prebuilt binaries for Linux and Apple.
        //
        // Pinned to a revision, not a version, until swift-cedar cuts the
        // release carrying `SymbolicCompiler` — the symbolic analysis IAM
        // phase 7 (#484) runs on policy writes. Move back to `from:` on the
        // tag; leaving a revision pin here means dependency updates stop
        // reaching us silently.
        .package(url: "https://github.com/samcat116/swift-cedar.git", from: "0.2.0"),
    ],
    targets: [
        // SPIRE Server registration API client (join tokens + registration
        // entries). A separate library target so tests can exercise it against
        // an in-process gRPC server and so the generated protobuf code stays
        // out of the App target.
        .target(
            name: "SPIREServerAPI",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "SPIFFEVerification", package: "shared"),
            ],
            exclude: ["Generated/README.md", "Generated/proto"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "App",
            dependencies: [
                .target(name: "SPIREServerAPI"),
                .product(name: "StratoShared", package: "shared"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "WebAuthn", package: "webauthn-swift"),
                .product(name: "SwiftSCIM", package: "swift-scim"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "SwiftSSF", package: "swift-ssf"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OTel", package: "swift-otel"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Valkey", package: "valkey-swift"),
                .product(name: "SotoS3", package: "soto"),
                .product(name: "CedarPolicy", package: "swift-cedar"),
            ],
            resources: [
                // Ship the spec so the control plane can serve it at runtime
                // (GET /api/openapi.yaml). This is the same file the
                // swift-openapi-generator build plugin consumes; declaring it a
                // resource additionally copies it into the product bundle.
                .copy("openapi.yaml")
            ],
            swiftSettings: swiftSettings,
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .target(name: "SPIREServerAPI"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            swiftSettings: testSwiftSettings
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

// VaporTesting's request/response closures are not yet compatible with
// NonisolatedNonsendingByDefault, so the test target only gets the
// non-behavioral feature.
var testSwiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("InferIsolatedConformances")
    ]
}
