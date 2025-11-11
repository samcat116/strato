// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SakeApp",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/kattouf/Sake.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "SakeApp",
            dependencies: [
                .product(name: "Sake", package: "Sake")
            ],
            path: ".",
            sources: ["Sakefile.swift"]
        )
    ]
)
