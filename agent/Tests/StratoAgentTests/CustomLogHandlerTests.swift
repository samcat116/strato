import Testing
import Foundation
import Logging
@testable import StratoAgentCore

@Suite("CustomLogHandler Tests")
struct CustomLogHandlerTests {

    @Test("CustomLogHandler initializes with correct defaults")
    func customLogHandlerInitialization() {
        let handler = CustomLogHandler(label: "test-logger")

        #expect(handler.logLevel == .info)
        #expect(handler.metadata.isEmpty)
    }

    @Test("Log level can be modified")
    func logLevelProperty() {
        var handler = CustomLogHandler(label: "test-logger")

        handler.logLevel = .debug
        #expect(handler.logLevel == .debug)

        handler.logLevel = .error
        #expect(handler.logLevel == .error)

        handler.logLevel = .trace
        #expect(handler.logLevel == .trace)
    }

    @Test("Metadata can be accessed via subscript")
    func metadataSubscript() {
        var handler = CustomLogHandler(label: "test-logger")

        handler[metadataKey: "key1"] = "value1"
        #expect(handler[metadataKey: "key1"] == "value1")

        handler[metadataKey: "key2"] = .string("value2")
        #expect(handler[metadataKey: "key2"] == .string("value2"))

        handler[metadataKey: "key1"] = nil
        #expect(handler[metadataKey: "key1"] == nil)
    }

    @Test("Metadata can be set as a whole")
    func metadataProperty() {
        var handler = CustomLogHandler(label: "test-logger")

        let metadata: Logger.Metadata = [
            "request_id": "12345",
            "user_id": "user-67890"
        ]
        handler.metadata = metadata

        #expect(handler.metadata["request_id"] == "12345")
        #expect(handler.metadata["user_id"] == "user-67890")
    }

    @Test("Metadata supports different value types")
    func metadataValueTypes() {
        var handler = CustomLogHandler(label: "test-logger")

        handler[metadataKey: "string"] = .string("test")
        handler[metadataKey: "stringConvertible"] = .stringConvertible(42)
        handler[metadataKey: "array"] = .array(["a", "b"])
        handler[metadataKey: "dictionary"] = .dictionary(["key": "value"])

        #expect(handler[metadataKey: "string"] == .string("test"))
        #expect(handler[metadataKey: "stringConvertible"] == .stringConvertible(42))
        #expect(handler[metadataKey: "array"] == .array(["a", "b"]))
        #expect(handler[metadataKey: "dictionary"] == .dictionary(["key": "value"]))
    }

    @Test("Logger can be created with custom handler")
    func loggerCreationWithCustomHandler() {
        LoggingSystem.bootstrap { label in
            CustomLogHandler(label: label)
        }

        var logger = Logger(label: "integration-test")
        logger.logLevel = .debug

        #expect(logger.logLevel == .debug)

        // Test that logging doesn't crash
        logger.info("Test message")
        logger.debug("Debug message", metadata: ["test_id": "12345"])
        logger.error("Error message")
    }

    @Test("Metadata can be added and removed")
    func emptyMetadata() {
        var handler = CustomLogHandler(label: "test-logger")

        #expect(handler.metadata.isEmpty)

        handler[metadataKey: "temp"] = "value"
        #expect(!handler.metadata.isEmpty)

        handler[metadataKey: "temp"] = nil
        #expect(handler.metadata.isEmpty)
    }

    @Test("Metadata can be merged")
    func metadataMerging() {
        var handler = CustomLogHandler(label: "test-logger")
        handler.metadata = ["global_key": "global_value"]

        #expect(handler.metadata["global_key"] == "global_value")

        handler[metadataKey: "local_key"] = "local_value"

        #expect(handler.metadata["global_key"] == "global_value")
        #expect(handler.metadata["local_key"] == "local_value")
    }

    @Test("Multiple handlers can coexist independently")
    func multipleHandlers() {
        var handler1 = CustomLogHandler(label: "handler-1")
        var handler2 = CustomLogHandler(label: "handler-2")

        handler1.logLevel = .debug
        handler2.logLevel = .error

        handler1[metadataKey: "handler"] = "1"
        handler2[metadataKey: "handler"] = "2"

        #expect(handler1.logLevel == .debug)
        #expect(handler2.logLevel == .error)
        #expect(handler1[metadataKey: "handler"] == "1")
        #expect(handler2[metadataKey: "handler"] == "2")
    }

    @Test("All log levels are supported", arguments: [
        Logger.Level.trace,
        Logger.Level.debug,
        Logger.Level.info,
        Logger.Level.notice,
        Logger.Level.warning,
        Logger.Level.error,
        Logger.Level.critical
    ])
    func logLevelFiltering(level: Logger.Level) {
        var handler = CustomLogHandler(label: "test-logger")
        handler.logLevel = level
        #expect(handler.logLevel == level)
    }
}
