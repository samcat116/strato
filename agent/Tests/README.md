# StratoAgent Tests

This directory contains unit tests for the Strato Agent components.

## Test Coverage

The following test suites have been created:

### 1. AgentConfigTests
- **Location**: `StratoAgentTests/AgentConfigTests.swift`
- **Coverage**: Comprehensive tests for agent configuration loading and validation
- **Tests include**:
  - Configuration initialization with various parameter combinations
  - TOML file loading and parsing
  - Error handling for missing files, invalid TOML, and missing required fields
  - Network mode validation (ovn vs user)
  - Platform-specific default configurations
  - Configuration encoding/decoding (Codable conformance)
  - Error message descriptions
  - Default config path constants

### 2. CustomLogHandlerTests
- **Location**: `StratoAgentTests/CustomLogHandlerTests.swift`
- **Coverage**: Tests for the custom logging handler implementation
- **Tests include**:
  - Log handler initialization
  - Log level filtering and management
  - Metadata handling (subscription, merging)
  - Log output format verification
  - Timestamp formatting (ISO 8601 without timezone)
  - Log level string formatting (TRACE, DEBUG, INFO, WARNING, ERROR, CRITICAL)
  - Integration with Swift's Logging framework
  - Different metadata value types

### 3. NetworkModeTests
- **Location**: `StratoAgentTests/NetworkModeTests.swift`
- **Coverage**: Tests for the NetworkMode enum
- **Tests include**:
  - Raw value validation
  - Encoding/decoding with JSON
  - Invalid mode handling

## Known Issues

### SwiftQEMU Compilation Error

Currently, the tests cannot run due to a **Swift 6 concurrency issue in the SwiftQEMU dependency**. The dependency violates Sendable protocol requirements in its NIO channel handlers.

**Error Summary:**
```
error: type 'QMPChannelHandler' does not conform to the 'Sendable' protocol
error: capture of 'handler' with non-sendable type 'QMPChannelHandler' in a `@Sendable` closure
```

**Impact:** All targets in the package fail to compile, including tests, until this upstream dependency issue is resolved.

**Workaround Attempted:**
- Created `StratoAgentCore` library target with testable code isolated from SwiftQEMU
- Tests properly import from `StratoAgentCore` instead of `StratoAgent`
- However, Swift Package Manager still attempts to build all targets, including the executable that depends on SwiftQEMU

**Resolution Options:**
1. Wait for SwiftQEMU to fix concurrency issues
2. Fork SwiftQEMU and apply fixes locally
3. Temporarily downgrade to Swift 5.x tools version (loses Swift 6 benefits)
4. Use compiler flags to disable strict concurrency checking (not recommended)

## Running Tests

Once the SwiftQEMU issue is resolved, tests can be run with:

```bash
cd agent
swift test
```

To run specific test suites:

```bash
swift test --filter AgentConfigTests
swift test --filter CustomLogHandlerTests
swift test --filter NetworkModeTests
```

## Test Structure

```
agent/
├── Sources/
│   ├── StratoAgentCore/      # Testable core components (no SwiftQEMU dependency)
│   │   ├── AgentConfig.swift
│   │   └── CustomLogHandler.swift
│   └── StratoAgent/           # Main agent executable
│       ├── Agent.swift
│       ├── QEMUService.swift
│       ├── WebSocketClient.swift
│       └── ...
└── Tests/
    └── StratoAgentTests/
        ├── AgentConfigTests.swift
        ├── CustomLogHandlerTests.swift
        └── NetworkModeTests.swift
```

## Test Quality

All tests follow XCTest best practices:
- Clear test names describing what is being tested
- Proper setup/teardown for test isolation
- Comprehensive edge case coverage
- Error condition testing
- Temporary file cleanup
- No test interdependencies

## Future Work

Additional test coverage should be added for:
- `Agent.swift` - Main agent coordination logic (requires mocking WebSocket and QEMU)
- `WebSocketClient.swift` - WebSocket communication (requires mock server)
- `QEMUService.swift` - VM lifecycle management (requires QEMU or advanced mocking)
- `NetworkServiceLinux.swift` / `NetworkServiceMacOS.swift` - Network management (platform-specific)

These components are more complex and require either:
- Mock implementations of external dependencies
- Integration test environment with actual services running
- Dependency injection patterns to allow test doubles
