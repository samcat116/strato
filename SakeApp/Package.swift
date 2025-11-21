// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SakeApp",
    platforms: [.macOS(.v13)], // Required by Sake -> swift-subprocess
    products: [
        .executable(name: "SakeApp", targets: ["SakeApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/kattouf/Sake", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "SakeApp",
            dependencies: [
                .product(name: "Sake", package: "Sake"),
            ],
            path: "."
        ),
    ]
)