import XCTest
import Foundation
import Logging
@testable import StratoAgentCore

final class CustomLogHandlerTests: XCTestCase {

    // MARK: - Initialization Tests

    func testCustomLogHandlerInitialization() {
        let handler = CustomLogHandler(label: "test-logger")

        XCTAssertEqual(handler.logLevel, .info, "Default log level should be info")
        XCTAssertTrue(handler.metadata.isEmpty, "Default metadata should be empty")
    }

    // MARK: - Log Level Tests

    func testLogLevelProperty() {
        var handler = CustomLogHandler(label: "test-logger")

        handler.logLevel = .debug
        XCTAssertEqual(handler.logLevel, .debug)

        handler.logLevel = .error
        XCTAssertEqual(handler.logLevel, .error)

        handler.logLevel = .trace
        XCTAssertEqual(handler.logLevel, .trace)
    }

    // MARK: - Metadata Tests

    func testMetadataSubscript() {
        var handler = CustomLogHandler(label: "test-logger")

        handler[metadataKey: "key1"] = "value1"
        XCTAssertEqual(handler[metadataKey: "key1"], "value1")

        handler[metadataKey: "key2"] = .string("value2")
        XCTAssertEqual(handler[metadataKey: "key2"], .string("value2"))

        handler[metadataKey: "key1"] = nil
        XCTAssertNil(handler[metadataKey: "key1"])
    }

    func testMetadataProperty() {
        var handler = CustomLogHandler(label: "test-logger")

        let metadata: Logger.Metadata = [
            "request_id": "12345",
            "user_id": "user-67890"
        ]
        handler.metadata = metadata

        XCTAssertEqual(handler.metadata["request_id"], "12345")
        XCTAssertEqual(handler.metadata["user_id"], "user-67890")
    }

    func testMetadataValueTypes() {
        var handler = CustomLogHandler(label: "test-logger")

        // Test different metadata value types
        handler[metadataKey: "string"] = .string("test")
        handler[metadataKey: "stringConvertible"] = .stringConvertible(42)
        handler[metadataKey: "array"] = .array(["a", "b"])
        handler[metadataKey: "dictionary"] = .dictionary(["key": "value"])

        XCTAssertEqual(handler[metadataKey: "string"], .string("test"))
        XCTAssertEqual(handler[metadataKey: "stringConvertible"], .stringConvertible(42))
        XCTAssertEqual(handler[metadataKey: "array"], .array(["a", "b"]))
        XCTAssertEqual(handler[metadataKey: "dictionary"], .dictionary(["key": "value"]))
    }

    // MARK: - Integration Tests

    func testLoggerCreationWithCustomHandler() {
        // Test that we can create a logger with our custom handler
        LoggingSystem.bootstrap { label in
            CustomLogHandler(label: label)
        }

        var logger = Logger(label: "integration-test")
        logger.logLevel = .debug

        // Verify logger was created with correct properties
        XCTAssertEqual(logger.logLevel, .debug)

        // Test that logging doesn't crash (output goes to stderr but we don't capture it)
        logger.info("Test message")
        logger.debug("Debug message", metadata: ["test_id": "12345"])
        logger.error("Error message")
    }

    func testEmptyMetadata() {
        var handler = CustomLogHandler(label: "test-logger")

        // Initially empty
        XCTAssertTrue(handler.metadata.isEmpty)

        // Add and remove
        handler[metadataKey: "temp"] = "value"
        XCTAssertFalse(handler.metadata.isEmpty)

        handler[metadataKey: "temp"] = nil
        XCTAssertTrue(handler.metadata.isEmpty)
    }

    func testMetadataMerging() {
        var handler = CustomLogHandler(label: "test-logger")
        handler.metadata = ["global_key": "global_value"]

        // Verify global metadata is set
        XCTAssertEqual(handler.metadata["global_key"], "global_value")

        // Add more metadata
        handler[metadataKey: "local_key"] = "local_value"

        // Both should be present
        XCTAssertEqual(handler.metadata["global_key"], "global_value")
        XCTAssertEqual(handler.metadata["local_key"], "local_value")
    }

    func testMultipleHandlers() {
        // Test that multiple handlers can coexist with different configurations
        var handler1 = CustomLogHandler(label: "handler-1")
        var handler2 = CustomLogHandler(label: "handler-2")

        handler1.logLevel = .debug
        handler2.logLevel = .error

        handler1[metadataKey: "handler"] = "1"
        handler2[metadataKey: "handler"] = "2"

        XCTAssertEqual(handler1.logLevel, .debug)
        XCTAssertEqual(handler2.logLevel, .error)
        XCTAssertEqual(handler1[metadataKey: "handler"], "1")
        XCTAssertEqual(handler2[metadataKey: "handler"], "2")
    }

    func testLogLevelFiltering() {
        var handler = CustomLogHandler(label: "test-logger")

        // Test all log levels
        let levels: [Logger.Level] = [.trace, .debug, .info, .notice, .warning, .error, .critical]

        for level in levels {
            handler.logLevel = level
            XCTAssertEqual(handler.logLevel, level, "Log level should match set value")
        }
    }
}
