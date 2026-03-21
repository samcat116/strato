# CLAUDE.md

## Project Overview

SwiftSSF is a Swift library implementing the **OpenID Shared Signals Framework (SSF)** receiver side. It enables Swift applications to receive and process security events (CAEP and RISC event types) from SSF transmitters via push (webhook) or poll delivery methods. The library handles JWT/SET (Security Event Token) parsing, signature verification, stream management, and event delivery.

## Build & Test

```bash
# Build
swift build

# Run tests
swift test

# Run the example receiver (requires real transmitter config)
swift run ExampleReceiver
```

- Swift Package Manager project, minimum Swift 5.9
- Platforms: macOS 10.15+, iOS 13+, watchOS 6+, tvOS 13+, visionOS 1+
- No Xcode project file; use `Package.swift` directly

## Dependencies

- **swift-nio** / **swift-nio-http2** - Networking and HTTP server (push delivery)
- **async-http-client** - HTTP client for transmitter API calls and polling
- **swift-crypto** - JWT signature verification (ES256 / P-256)
- **swift-log** - Structured logging throughout

## Project Structure

```
Sources/
  SwiftSSF/
    SwiftSSF.swift              # Framework constants (version, supported events/delivery methods)
    SSFReceiver.swift           # Main public API: SSFReceiver actor, SSFReceiverConfiguration, SSFEventHandler protocol
    Client/
      SSFHTTPClient.swift       # HTTP client actor for transmitter REST API (streams, polling, discovery)
    Delivery/
      PollEventDelivery.swift   # Poll-based delivery: PollEventDelivery actor, MultiStreamPollManager, BackoffStrategy
      PushEventDelivery.swift   # Push-based delivery: PushEventDelivery (NIO HTTP server), SSFWebhookHandler, MultiStreamPushServer
    JWT/
      JWKSClient.swift          # JWKS fetching/caching actor, JWKSet/JWK models
      JWTProcessor.swift        # JWT parsing, SET validation, signature verification, base64url Data extensions
    Models/
      SecurityEvent.swift       # SecurityEvent protocol, CAEPEvent/RISCEvent enums, individual event structs
      SecurityEventToken.swift  # SecurityEventToken, JWTHeader, SecurityEventPayload, SubjectIdentifier, AnyCodable, AnyCodingKey
      SSFError.swift            # SSFError enum (all error cases), SSFHTTPError, SSFErrorCode
      Stream.swift              # EventStream, DeliveryConfiguration, DeliveryMethod, StreamStatus, request/response types
  ExampleReceiver/
    main.swift                  # Example app demonstrating poll + push setup, stream management
Tests/
  SwiftSSFTests/
    SwiftSSFTests.swift              # Framework constants, config, error types
    JWTProcessorTests.swift          # JWT parsing, token creation/validation, signature verification
    SecurityEventTokenTests.swift    # Token model, SubjectIdentifier encoding, AnyCodable
    StreamTests.swift                # Stream models, delivery config, serialization round-trips
```

## Architecture & Key Patterns

- **Actor-based concurrency**: Core types (`SSFReceiver`, `SSFHTTPClient`, `JWTProcessor`, `JWKSClient`, `PollEventDelivery`, `MultiStreamPollManager`, `MultiStreamPushServer`) are all Swift actors for thread-safe mutable state.
- **`PushEventDelivery`** is a `final class` (not actor) marked `Sendable` because it wraps NIO's `Channel`/`ServerBootstrap` which have their own thread safety. The `SSFWebhookHandler` is a NIO `ChannelInboundHandler`.
- **Protocol-based event handling**: `SSFEventHandler` protocol with `handleEvent(_:)` and `handleError(_:token:)`. Users implement this to process events. `LoggingEventHandler` is a built-in default.
- **Caching**: `SSFReceiver` caches JWKS and transmitter configuration. `JWKSClient` has a 1-hour TTL key cache. Call `clearCache()` to invalidate.
- **JSON coding**: Uses `secondsSince1970` date strategy. Model property names use snake_case to match the SSF/JWT JSON wire format directly (e.g., `events_requested`, `endpoint_url`, `sub_id`).
- **AnyCodable**: Custom type-erased `Codable` wrapper in `SecurityEventToken.swift` for dynamic JSON payloads. Used in event payloads, subject identifiers, delivery configs, and error details.
- **DynamicKey / AnyCodingKey**: Custom `CodingKey` types for decoding dynamic JSON keys in CAEP/RISC event enums and `ComplexSubjectIdentifier`.
- **Base64URL**: `Data` extensions in `JWTProcessor.swift` for base64url encode/decode (also duplicated in test file).
- **Convenience extensions**: `SSFReceiver` has extensions in the delivery files (`startPolling`, `startPushServer`) to simplify setup.

## Coding Conventions

- All public types and methods have `///` doc comments.
- `// MARK: -` sections used to organize code within files (Stream Management, Event Processing, Discovery, Private Methods, etc.).
- Structs conforming to `Codable` and `Sendable` for all model/data types.
- Enums with raw `String` values for wire-format constants (`DeliveryMethod`, `StreamStatus`, `SSFErrorCode`, `VerificationStatus`), all conforming to `CaseIterable`.
- `SSFError` is the unified error enum; all errors funnel through it. Uses `LocalizedError` with `errorDescription`.
- Logging uses `swift-log` `Logger` instances, one per type, with descriptive labels like `"SwiftSSF.Receiver"`, `"SwiftSSF.HTTPClient"`.
- Tests use XCTest with `@testable import SwiftSSF`. Async tests use `async throws`. Test methods follow `test<Feature>` naming.
- Explicit `public init()` on all public structs (memberwise initializers with defaults).
- Only ES256 (P-256 ECDSA) signatures are supported for JWT verification.
- HTTP response body reads are capped at 1MB (`1024 * 1024`).
- Request timeout is 30 seconds throughout.
