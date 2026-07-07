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
    .package(url: "https://github.com/vapor/vapor.git", from: "4.113.0"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        // 🐘 Fluent driver for Postgres.
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        // 🪶 Fluent driver for SQLite (for testing).
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.71.0"),
        // 🔐 WebAuthn/Passkey authentication
        .package(url: "https://github.com/swift-server/webauthn-swift.git", branch: "main"),
        .package(url: "https://github.com/samcat116/swift-scim.git", branch: "main"),
        // 🔐 JWT token handling and HTTP client functionality
        .package(url: "https://github.com/vapor/jwt.git", from: "4.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.9.0"),
        // 🔐 Swift Crypto for cryptographic operations
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
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
        // 🔴 Valkey/Redis support for caching and sessions
        .package(url: "https://github.com/vapor/redis.git", from: "4.0.0"),
        // SPIRE Server registration API (gRPC over Unix socket / loopback TCP)
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
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
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "WebAuthn", package: "webauthn-swift"),
                .product(name: "SwiftSCIM", package: "swift-scim"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OTel", package: "swift-otel"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Redis", package: "redis")
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
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf")
            ],
            swiftSettings: testSwiftSettings
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

// VaporTesting's request/response closures are not yet compatible with
// NonisolatedNonsendingByDefault, so the test target only gets the
// non-behavioral feature.
var testSwiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("InferIsolatedConformances"),
    ]
}
