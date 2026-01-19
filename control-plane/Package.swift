// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "strato",
    platforms: [
        .macOS(.v14)
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
        // OpenAPI generator and Vapor bindings (spec-first)
        .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-vapor.git", from: "1.0.0"),
        // 📊 OpenTelemetry observability (metrics, logging, tracing)
        .package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.0.0"),
        // 🔴 Valkey/Redis support for caching and sessions
        .package(url: "https://github.com/vapor/redis.git", from: "4.0.0")
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
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
                .product(name: "OpenAPIVapor", package: "swift-openapi-vapor"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OTel", package: "swift-otel"),
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
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
            ],
            swiftSettings: swiftSettings
        )
    ],
    swiftLanguageModes: [.v6]
)

var swiftSettings: [SwiftSetting] {
    // Minimal settings for Swift 6 compatibility
    []
}
