# CLAUDE.md

## Project Overview

SwiftOVN is a Swift library for managing OVN (Open Virtual Network) and OVS (Open vSwitch) through their JSON-RPC APIs over Unix domain sockets. It implements the OVSDB Management Protocol (RFC 7047) using SwiftNIO for async socket communication.

## Build / Run / Test

```bash
# Build the library
swift build

# Run tests (unit tests only, no live OVN/OVS connection required)
swift test

# Run the example (requires access to OVN/OVS Unix sockets)
swift run BasicUsage
```

- Swift 5.9+ required
- Swift Package Manager is the build system (Package.swift)
- Minimum deployment: macOS 13, iOS 16, watchOS 9, tvOS 16, visionOS 1

## Dependencies

- **swift-nio** (2.65.0+) - Async networking, Unix domain socket transport
- **swift-log** (1.0.0+) - Structured logging

## Project Structure

```
Sources/SwiftOVN/
  Core/                  # Low-level networking and protocol
    UnixSocketConnection   - SwiftNIO Unix domain socket with line-delimited framing
    JSONRPCClient          - JSON-RPC 2.0 client over UnixSocketConnection
    OVSDBConnection        - OVSDB protocol layer (transact, monitor, CRUD)
  Managers/              # High-level typed APIs
    OVNManager             - OVN operations (logical switches, routers, ACLs, NAT, DHCP, etc.)
    OVSManager             - OVS operations (bridges, ports, interfaces, mirrors, QoS, etc.)
  Protocols/             # Protocol definitions + database/table constants
    OVNManaging            - OVNManager protocol + OVNDatabase/OVNTable enums
    OVSManaging            - OVSManager protocol + OVSDatabase/OVSTable enums + OVSFlowBuilder
  Models/                # One file per model, all Codable structs/enums
    JSONRPC types          - JSONRPCRequest, JSONRPCResponse, JSONRPCError, JSONRPCIdentifier, JSONRPCParams
    JSONValue              - Recursive Codable enum for arbitrary JSON
    OVSDB types            - OVSDBOperation, OVSDBCondition, OVSDBMutation, OVSDBRow, OVSDBUpdate, etc.
    OVN models             - OVNLogicalSwitch, OVNLogicalRouter, OVNACL, OVNLoadBalancer, OVNNAT, etc.
    OVS models             - OVSBridge, OVSPort, OVSInterface, OVSController, OVSFlow, OVSMirror, etc.
    OVNManagerError        - Central error enum for all error cases
  Extensions/
    Codable+Extensions     - JSONValue helpers (set/map/uuid handling), OVSDBCondition/Mutation convenience inits
  OVNManagerModule.swift   - Module-level documentation
Examples/
  BasicUsage.swift         - Executable example target demonstrating OVN and OVS operations
Tests/SwiftOVNTests/
  OVNManagerTests.swift    - Unit tests for models, serialization, and builders (no network tests)
```

## Architecture

The layered stack flows: **Manager -> OVSDBConnection -> JSONRPCClient -> UnixSocketConnection**

- `UnixSocketConnection` uses SwiftNIO `ClientBootstrap` with a line-delimited frame decoder to communicate over Unix domain sockets. It returns `EventLoopFuture` values.
- `JSONRPCClient` wraps the connection with JSON-RPC 2.0 request/response handling. It bridges to async/await via `.get()` on futures.
- `OVSDBConnection` provides typed OVSDB operations: `selectAll`, `select`, `insert`, `update`, `delete`, `mutate`, plus monitoring.
- `OVNManager` and `OVSManager` are the public-facing APIs that operate on typed model structs. They serialize models to/from `OVSDBRow` (`[String: JSONValue]`) using `JSONSerialization` round-tripping through `Codable`.

## Key Patterns and Conventions

### Naming
- OVN entity models are prefixed `OVN` (e.g., `OVNLogicalSwitch`, `OVNACL`, `OVNNAT`)
- OVS entity models are prefixed `OVS` (e.g., `OVSBridge`, `OVSPort`)
- OVSDB protocol types are prefixed `OVSDB` (e.g., `OVSDBOperation`, `OVSDBCondition`)
- JSON-RPC types are prefixed `JSONRPC` (e.g., `JSONRPCRequest`, `JSONRPCResponse`)

### Model Conventions
- All models are `public struct` conforming to `Codable`
- One model per file, file named after the type
- Properties use `snake_case` to match OVSDB column names (e.g., `external_ids`, `fail_mode`, `other_config`)
- `uuid` property maps to `_uuid` via CodingKeys and is `String?` (nil when creating, populated when reading)
- `uuid` is excluded during insert operations (the `createRow` helper skips `_uuid`)
- Most properties are optional except identifying fields like `name`
- Memberwise `public init` with defaults for optional parameters

### Error Handling
- Single `OVNManagerError` enum used across the entire codebase (both OVN and OVS operations)
- Cases: `connectionFailed`, `invalidResponse`, `timeoutError`, `encodingError`, `decodingError`, `rpcError`, `invalidSocket`, `operationFailed`
- All async operations are `throws`

### Concurrency
- Public APIs use `async throws`
- Internal NIO operations use `EventLoopFuture` bridged to async via `.get()`
- Thread safety via `NSLock` for shared mutable state (request IDs, active monitors)
- Monitoring uses `AsyncThrowingStream` for real-time database change events

### CRUD Pattern
Each entity type follows the same pattern in its manager:
- `getAll() -> [Model]` - select all rows, parse via `compactMap`
- `get(named:) -> Model?` - select with `OVSDBCondition`, return first match
- `create(_ model) -> String` - insert row, extract UUID from `["uuid", "<value>"]` response format
- `update(uuid:, _ model)` - update with UUID condition, throw if count == 0
- `delete(uuid:)` / `delete(named:)` - delete with condition, throw if count == 0

### JSON Handling
- `JSONValue` is a recursive enum (`string`, `number`, `boolean`, `null`, `array`, `object`) with custom `Codable`
- `OVSDBRow` is a typealias for `[String: JSONValue]`
- OVSDB UUID format is `["uuid", "<uuid-string>"]`
- OVSDB set format is `["set", [...]]` (single values unwrapped)
- OVSDB map format is `["map", [[key, value], ...]]`
- Helpers for these formats are in `Codable+Extensions.swift`

### Code Organization
- `// MARK: -` comments separate logical sections within files
- `private extension` for internal helper methods on managers
- `public extension` for protocol default implementations and convenience methods
- Database and table names are static string constants on caseless enums (`OVNDatabase`, `OVNTable`, `OVSDatabase`, `OVSTable`)

### Tests
- Tests use `XCTest` framework
- Test target imports `@testable import OVNManager` (note: the module was previously named `OVNManager`, now `SwiftOVN`)
- Tests cover model creation, serialization round-trips, and builder patterns
- No integration/network tests -- all tests are unit tests against models and serialization

### Limitations
- OVS flow operations (`addFlow`, `deleteFlow`, `modifyFlow`) are stub implementations that throw errors -- flow management requires `ovs-ofctl` commands, not OVSDB
- The `UnixSocketConnection` uses `EventLoopFuture` rather than structured concurrency throughout
