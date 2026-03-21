# SwiftSSF

A cross-platform Swift framework for implementing OpenID Shared Signals Framework (SSF) receivers. This framework enables Swift applications running on macOS, Linux, and Windows to receive and process security events through the SSF protocol.

## Features

- 🔄 Support for both CAEP and RISC event types
- 📡 Push and poll-based event delivery
- 🔐 JWT/SET validation and parsing
- 🌐 Cross-platform compatibility (macOS, Linux, Windows)
- ⚡ Built on Swift-NIO for high performance
- 🔒 Secure event transmission and validation

## Quick Start

```swift
import SwiftSSF

// Create an SSF receiver
let receiver = SSFReceiver(
    configuration: .init(
        transmitterURL: "https://transmitter.example.com",
        authToken: "your_auth_token"
    )
)

// Poll for events
let events = try await receiver.pollEvents()

// Or setup push delivery
let server = try await receiver.startPushServer(port: 8080) { event in
    print("Received event: \(event.type)")
}
```

## Requirements

- Swift 5.9+
- macOS 10.15+ / iOS 13+ / Linux / Windows

## Installation

Add SwiftSSF to your Swift package dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/swift-ssf.git", from: "1.0.0")
]
```

## Documentation

For detailed documentation and examples, see the [docs](./docs/) directory.

## License

MIT License - see [LICENSE](LICENSE) for details.