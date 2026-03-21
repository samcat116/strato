// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "swift-qemu",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SwiftQEMU",
            targets: ["SwiftQEMU"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SwiftQEMU",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "SwiftQEMUTests",
            dependencies: ["SwiftQEMU"]
        ),
    ]
)