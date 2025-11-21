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

    // MARK: - Log Output Tests

    func testLogOutputFormat() {
        // This test captures stderr output and verifies the log format
        let handler = CustomLogHandler(label: "test-logger")

        // Create a pipe to capture output
        let pipe = Pipe()
        let originalStderr = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        // Log a message
        handler.log(
            level: .info,
            message: "Test message",
            metadata: nil,
            source: "TestSource",
            file: "TestFile.swift",
            function: "testFunction",
            line: 42
        )

        // Restore stderr
        fflush(stderr)
        dup2(originalStderr, STDERR_FILENO)
        close(originalStderr)

        // Read captured output
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Verify output format
        XCTAssertTrue(output.contains("INFO"), "Should contain log level")
        XCTAssertTrue(output.contains("test-logger"), "Should contain label")
        XCTAssertTrue(output.contains("Test message"), "Should contain message")
        XCTAssertTrue(output.contains("[TestSource]"), "Should contain source")
    }

    func testLogOutputWithMetadata() {
        let handler = CustomLogHandler(label: "test-logger")

        let pipe = Pipe()
        let originalStderr = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        let metadata: Logger.Metadata = [
            "request_id": "abc123",
            "user_id": "user456"
        ]

        handler.log(
            level: .debug,
            message: "Debug message",
            metadata: metadata,
            source: "TestSource",
            file: "TestFile.swift",
            function: "testFunction",
            line: 10
        )

        fflush(stderr)
        dup2(originalStderr, STDERR_FILENO)
        close(originalStderr)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(output.contains("DEBUG"), "Should contain log level")
        XCTAssertTrue(output.contains("request_id"), "Should contain metadata key")
        XCTAssertTrue(output.contains("abc123"), "Should contain metadata value")
    }

    func testLogOutputWithMergedMetadata() {
        var handler = CustomLogHandler(label: "test-logger")
        handler.metadata = ["global_key": "global_value"]

        let pipe = Pipe()
        let originalStderr = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        let localMetadata: Logger.Metadata = ["local_key": "local_value"]

        handler.log(
            level: .warning,
            message: "Warning message",
            metadata: localMetadata,
            source: "TestSource",
            file: "TestFile.swift",
            function: "testFunction",
            line: 20
        )

        fflush(stderr)
        dup2(originalStderr, STDERR_FILENO)
        close(originalStderr)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(output.contains("global_key"), "Should contain global metadata")
        XCTAssertTrue(output.contains("global_value"), "Should contain global metadata value")
        XCTAssertTrue(output.contains("local_key"), "Should contain local metadata")
        XCTAssertTrue(output.contains("local_value"), "Should contain local metadata value")
    }

    func testLogLevelFormatting() {
        let handler = CustomLogHandler(label: "test-logger")

        let testCases: [(Logger.Level, String)] = [
            (.trace, "TRACE"),
            (.debug, "DEBUG"),
            (.info, "INFO"),
            (.notice, "NOTICE"),
            (.warning, "WARNING"),
            (.error, "ERROR"),
            (.critical, "CRITICAL")
        ]

        for (level, expectedString) in testCases {
            let pipe = Pipe()
            let originalStderr = dup(STDERR_FILENO)
            dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

            handler.log(
                level: level,
                message: "Test",
                metadata: nil,
                source: "Test",
                file: "Test.swift",
                function: "test",
                line: 1
            )

            fflush(stderr)
            dup2(originalStderr, STDERR_FILENO)
            close(originalStderr)

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            XCTAssertTrue(output.contains(expectedString), "Should contain \(expectedString)")
        }
    }

    // MARK: - Timestamp Tests

    func testTimestampFormat() {
        let handler = CustomLogHandler(label: "test-logger")

        let pipe = Pipe()
        let originalStderr = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        handler.log(
            level: .info,
            message: "Test",
            metadata: nil,
            source: "Test",
            file: "Test.swift",
            function: "test",
            line: 1
        )

        fflush(stderr)
        dup2(originalStderr, STDERR_FILENO)
        close(originalStderr)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Timestamp should be in format: yyyy-MM-dd'T'HH:mm:ss
        let timestampPattern = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"#
        let regex = try? NSRegularExpression(pattern: timestampPattern)
        let range = NSRange(output.startIndex..., in: output)
        let matches = regex?.firstMatch(in: output, range: range)

        XCTAssertNotNil(matches, "Output should contain a properly formatted timestamp")
    }

    // MARK: - Integration Tests

    func testLoggerWithCustomHandler() {
        LoggingSystem.bootstrap { label in
            CustomLogHandler(label: label)
        }

        var logger = Logger(label: "integration-test")
        logger.logLevel = .debug

        let pipe = Pipe()
        let originalStderr = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        logger.info("Integration test message", metadata: ["test_id": "12345"])

        fflush(stderr)
        dup2(originalStderr, STDERR_FILENO)
        close(originalStderr)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(output.contains("INFO"))
        XCTAssertTrue(output.contains("integration-test"))
        XCTAssertTrue(output.contains("Integration test message"))
        XCTAssertTrue(output.contains("test_id"))
    }

    func testEmptyMetadata() {
        let handler = CustomLogHandler(label: "test-logger")

        let pipe = Pipe()
        let originalStderr = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        handler.log(
            level: .info,
            message: "Message without metadata",
            metadata: [:],
            source: "Test",
            file: "Test.swift",
            function: "test",
            line: 1
        )

        fflush(stderr)
        dup2(originalStderr, STDERR_FILENO)
        close(originalStderr)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Should still have proper format even with empty metadata
        XCTAssertTrue(output.contains("INFO"))
        XCTAssertTrue(output.contains("Message without metadata"))
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
}
