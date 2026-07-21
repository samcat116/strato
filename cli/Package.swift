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
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/samcat116/swift-toml.git", branch: "master"),
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
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "StratoCLI",
            dependencies: [
                "StratoCLICore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StratoCLITests",
            dependencies: ["StratoCLICore"],
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
