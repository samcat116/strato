// swift-tools-version:6.4
import Foundation
import PackageDescription

let runtime = ProcessInfo.processInfo.environment["STRATO_PROTOBUF_RUNTIME_PATH"]
let package = Package(
    name: "AgentProtocolPeers",
    dependencies: [
        runtime.map { .package(path: $0) }
            ?? .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1")
    ],
    targets: [
        .target(name: "BaselinePeer", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .target(name: "NextPeer", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .executableTarget(
            name: "CompatibilityProbe",
            dependencies: ["BaselinePeer", "NextPeer", .product(name: "SwiftProtobuf", package: "swift-protobuf")]),
    ]
)
