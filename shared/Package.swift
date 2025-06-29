// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "StratoShared",
    platforms: [
        .macOS(.v14),
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "StratoShared",
            targets: ["StratoShared"]
        ),
    ],
    dependencies: [
        // Foundation only - minimal dependencies for shared code
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "StratoShared",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)