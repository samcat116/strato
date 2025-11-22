# StratoAgent Tests

This directory contains unit tests for the Strato Agent components using **Swift Testing** framework.

## Test Framework

Tests use Apple's modern **Swift Testing** framework (not XCTest), which provides:
- **`@Test`** attributes for test methods
- **`#expect`** assertions instead of XCTAssert*
- **`@Suite`** for test organization
- **Parameterized tests** with the `arguments` parameter
- Better async/await support
- Parallel test execution by default
- More expressive and Swift-native syntax

## Test Coverage

The following test suites have been created:

### 1. AgentConfigTests (16 tests)
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

### 2. CustomLogHandlerTests (10 tests)
- **Location**: `StratoAgentTests/CustomLogHandlerTests.swift`
- **Coverage**: Tests for the custom logging handler implementation
- **Tests include**:
  - Log handler initialization
  - Log level filtering and management
  - Metadata handling (subscription, merging)
  - Integration with Swift's Logging framework
  - Different metadata value types
  - **Parameterized test** for all log levels (trace, debug, info, notice, warning, error, critical)

### 3. NetworkModeTests (5 tests)
- **Location**: `StratoAgentTests/NetworkModeTests.swift`
- **Coverage**: Tests for the NetworkMode enum
- **Tests include**:
  - Raw value validation
  - Encoding/decoding with JSON
  - Invalid mode handling

## Running Tests

To run all tests:

```bash
cd agent
swift test
```

To run specific test suites:

```bash
swift test --filter "AgentConfig Tests"
swift test --filter "CustomLogHandler Tests"
swift test --filter "NetworkMode Tests"
```

To run a specific test:

```bash
swift test --filter "Load valid TOML configuration"
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

## Test Results

Latest test run (all passing ✅):

```
✔ Test run with 29 tests passed
  ├── AgentConfig Tests: 16 tests passed
  ├── CustomLogHandler Tests: 10 tests passed (1 parameterized with 7 runs)
  └── NetworkMode Tests: 5 tests passed
```

## Test Quality

All tests follow Swift Testing best practices:
- Clear, descriptive test names in `@Test` attributes
- Proper resource cleanup using `defer`
- Comprehensive edge case coverage
- Error condition testing with `#expect(throws:)`
- Temporary file cleanup in file-based tests
- No test interdependencies
- Parameterized tests for testing multiple inputs

## Writing New Tests

When adding new tests, follow these patterns:

```swift
import Testing
@testable import StratoAgentCore

@Suite("Feature Tests")
struct FeatureTests {

    @Test("Feature does something")
    func featureBehavior() {
        let result = someFunction()
        #expect(result == expectedValue)
    }

    @Test("Feature throws error on invalid input")
    func featureErrorHandling() {
        #expect(throws: SomeError.self) {
            try someThrowingFunction()
        }
    }

    @Test("Feature works with multiple inputs", arguments: [
        "input1", "input2", "input3"
    ])
    func featureWithMultipleInputs(input: String) {
        let result = process(input)
        #expect(!result.isEmpty)
    }
}
```

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
