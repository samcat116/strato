// swift-tools-version:6.0
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
        .package(url: "https://github.com/vapor/vapor.git", from: "4.110.1"),
        // 🗄 An ORM for SQL and NoSQL databases.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.9.0"),
        // 🐘 Fluent driver for Postgres.
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        // 🎯 Type-safe HTML DSL for Swift
        .package(url: "https://github.com/sliemeobn/elementary.git", from: "0.5.0"),
        // 🎯 HTMX integration for Swift with type-safe HTML DSL
        .package(url: "https://github.com/sliemeobn/elementary-htmx.git", from: "0.4.0"),
        // 🔵 Non-blocking, event-driven networking for Swift. Used for custom executors
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // 🔐 WebAuthn/Passkey authentication
        .package(url: "https://github.com/swift-server/webauthn-swift.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "StratoShared", package: "shared"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Elementary", package: "elementary"),
                .product(name: "ElementaryHTMX", package: "elementary-htmx"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "WebAuthn", package: "webauthn-swift"),
            ],
            swiftSettings: swiftSettings
        )
    ],
    swiftLanguageModes: [.v5]
)

var swiftSettings: [SwiftSetting] {
    // Minimal settings for Swift 6 compatibility
    []
}
