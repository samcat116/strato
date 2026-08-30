// swift-tools-version:6.2
import PackageDescription

// The Strato API client, generated from the same `openapi.yaml` the control
// plane serves (issue #583). `Sources/StratoAPIClient/openapi.yaml` is a symlink
// to `control-plane/Sources/App/openapi.yaml`, so there is exactly one spec in
// the repository and the client cannot drift from the server.
let package = Package(
    name: "strato-api-client",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "StratoAPIClient", targets: ["StratoAPIClient"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "StratoAPIClient",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")
            ],
            // The generator plugin reads the spec from the target's own input
            // files, so it has to be declared rather than excluded.
            resources: [.copy("openapi.yaml")],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
            ]
        ),
        .testTarget(
            name: "StratoAPIClientTests",
            dependencies: ["StratoAPIClient"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
