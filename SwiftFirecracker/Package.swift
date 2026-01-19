// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SwiftFirecracker",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SwiftFirecracker",
            targets: ["SwiftFirecracker"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SwiftFirecracker",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "SwiftFirecrackerTests",
            dependencies: ["SwiftFirecracker"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
