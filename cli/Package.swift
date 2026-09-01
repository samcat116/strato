// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "strato-cli",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "strato", targets: ["StratoCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
        .package(url: "https://github.com/samcat116/swift-toml.git", branch: "master"),
        // The generated API client (issue #583). Its `openapi.yaml` is a
        // symlink to the control plane's, so the CLI is compiled against the
        // server's own contract: a breaking spec change breaks this build
        // rather than surfacing as a runtime decode failure later.
        .package(name: "strato-api-client", path: "../clients/swift"),
        // Used directly by the CLI's transport and middlewares, not just
        // transitively through the generated client.
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.16.0"),
    ],
    targets: [
        // Core library with all testable logic: config/credentials, HTTP
        // client, device-flow auth, output rendering. The executable target
        // cannot be imported by tests, so it stays thin.
        .target(
            name: "StratoCLICore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Toml", package: "swift-toml"),
                .product(name: "StratoAPIClient", package: "strato-api-client"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "StratoCLI",
            dependencies: [
                "StratoCLICore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "StratoAPIClient", package: "strato-api-client"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StratoCLITests",
            dependencies: [
                "StratoCLICore",
                .product(name: "StratoAPIClient", package: "strato-api-client"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
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
