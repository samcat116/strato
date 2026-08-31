import Foundation
import Logging
import StratoShared
import Synchronization
import Testing

@testable import StratoAgentCore

private enum HandlerTestError: Error, CustomStringConvertible {
    case exploded

    var description: String { "the operation exploded" }
}

private final class RecordingLogDestination: Sendable {
    private struct State: Sendable {
        var activeWrites = 0
        var maximumConcurrentWrites = 0
        var records: [Data] = []
    }

    private let state = Mutex(State())
    private let delayWrites: Bool

    init(delayWrites: Bool = false) {
        self.delayWrites = delayWrites
    }

    func write(_ data: Data) {
        state.withLock { state in
            state.activeWrites += 1
            state.maximumConcurrentWrites = max(state.maximumConcurrentWrites, state.activeWrites)
        }
        if delayWrites {
            Thread.sleep(forTimeInterval: 0.0005)
        }
        state.withLock { state in
            state.records.append(data)
            state.activeWrites -= 1
        }
    }

    var records: [Data] {
        state.withLock(\.records)
    }

    var maximumConcurrentWrites: Int {
        state.withLock(\.maximumConcurrentWrites)
    }
}

@Suite("Custom log handler")
struct CustomLogHandlerTests {
    private static let fixedDate = Date(timeIntervalSince1970: 1_767_225_600.123)

    private func makeHandler(
        label: String = "test-handler",
        metadataProvider: Logger.MetadataProvider? = nil,
        destination: RecordingLogDestination
    ) -> CustomLogHandler {
        let writer = SerializedLogRecordWriter { destination.write($0) }
        return CustomLogHandler(
            label: label,
            metadataProvider: metadataProvider,
            output: writer,
            now: { Self.fixedDate })
    }

    private func event(
        level: Logger.Level = .info,
        message: Logger.Message,
        error: (any Error)? = nil,
        metadata: Logger.Metadata? = nil,
        source: String = "StratoAgentTests"
    ) -> LogEvent {
        LogEvent(
            level: level,
            message: message,
            error: error,
            metadata: metadata,
            source: source,
            file: "CustomLogHandlerTests.swift",
            function: "test",
            line: 1)
    }

    private func parseRecord(_ data: Data) throws -> [String: Any] {
        #expect(data.count <= CustomLogHandler.maximumRecordBytes)
        #expect(data.last == 0x0A)

        let payload = Data(data.dropLast())
        #expect(!payload.contains(0x0A))
        #expect(!payload.contains(0x0D))
        #expect(!payload.contains(0x00))

        let decoded = try JSONSerialization.jsonObject(with: payload)
        return try #require(decoded as? [String: Any])
    }

    @Test("A typed error is retained as structured metadata")
    func preservesTypedError() throws {
        let destination = RecordingLogDestination()
        let handler = makeHandler(destination: destination)
        var logger = Logger(label: "typed-error") { _ in handler }
        logger.logLevel = .trace

        logger.error("Operation failed", error: HandlerTestError.exploded)

        let data = try #require(destination.records.first)
        let record = try parseRecord(data)
        let metadata = try #require(record["metadata"] as? [String: Any])
        #expect(metadata["error.type"] as? String == String(reflecting: HandlerTestError.self))
        #expect(metadata["error.message"] as? String == "the operation exploded")
        #expect(record["message"] as? String == "Operation failed")
        #expect(record["level"] as? String == "ERROR")
    }

    @Test("JSON output is deterministic for nested metadata")
    func deterministicallyEncodesNestedMetadata() throws {
        var firstNested: Logger.Metadata = [:]
        firstNested["z"] = "last"
        firstNested["a"] = .array(["first", "second"])

        var secondNested: Logger.Metadata = [:]
        secondNested["a"] = .array(["first", "second"])
        secondNested["z"] = "last"

        var firstMetadata: Logger.Metadata = [:]
        firstMetadata["z"] = "tail"
        firstMetadata["nested"] = .dictionary(firstNested)
        firstMetadata["a"] = "head"

        var secondMetadata: Logger.Metadata = [:]
        secondMetadata["a"] = "head"
        secondMetadata["nested"] = .dictionary(secondNested)
        secondMetadata["z"] = "tail"

        let firstDestination = RecordingLogDestination()
        let secondDestination = RecordingLogDestination()
        makeHandler(destination: firstDestination).log(
            event: event(message: "same", metadata: firstMetadata))
        makeHandler(destination: secondDestination).log(
            event: event(message: "same", metadata: secondMetadata))

        let first = try #require(firstDestination.records.first)
        let second = try #require(secondDestination.records.first)
        #expect(first == second)

        let record = try parseRecord(first)
        let metadata = try #require(record["metadata"] as? [String: Any])
        let nested = try #require(metadata["nested"] as? [String: Any])
        #expect(nested["a"] as? [String] == ["first", "second"])
        #expect(nested["z"] as? String == "last")
    }

    @Test("Control characters remain inside one parseable JSON line")
    func escapesControlCharactersAndUsesFractionalUTC() throws {
        let destination = RecordingLogDestination()
        let label = "handler\n\"quoted\""
        let source = "source\r\nwith-tab\t"
        let message = "first\nsecond\rthird\t\u{0000}\\\""
        let metadataKey = "key\nwith-control"
        let metadataValue = "value\r\n\t\u{0000}\\\""

        makeHandler(label: label, destination: destination).log(
            event: event(
                message: Logger.Message(stringLiteral: message),
                metadata: [metadataKey: .string(metadataValue)],
                source: source))

        let record = try parseRecord(try #require(destination.records.first))
        #expect(record["label"] as? String == label)
        #expect(record["source"] as? String == source)
        #expect(record["message"] as? String == message)
        let metadata = try #require(record["metadata"] as? [String: Any])
        #expect(metadata[metadataKey] as? String == metadataValue)

        let timestamp = try #require(record["timestamp"] as? String)
        #expect(timestamp.hasSuffix("Z"))
        #expect(timestamp.contains("."))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(formatter.date(from: timestamp) != nil)
    }

    @Test("Each metadata layer is canonicalized before later layers override it")
    func aliasPrecedence() throws {
        let destination = RecordingLogDestination()
        let provider = Logger.MetadataProvider {
            [
                "vm_id": "provider-vm",
                "request_id": "provider-request",
            ]
        }
        var handler = makeHandler(metadataProvider: provider, destination: destination)
        handler.metadata = [
            LogMetadata.Key.vmID: "base-vm",
            LogMetadata.Key.requestID: "base-request",
        ]

        handler.log(
            event: event(
                message: "aliases",
                metadata: [
                    "vmId": "event-vm",
                    "request-id": "event-request",
                    "projectId": "alias-project",
                    LogMetadata.Key.projectID: "canonical-project",
                ]))

        let record = try parseRecord(try #require(destination.records.first))
        let metadata = try #require(record["metadata"] as? [String: Any])
        #expect(metadata[LogMetadata.Key.vmID] as? String == "event-vm")
        #expect(metadata[LogMetadata.Key.requestID] as? String == "event-request")
        #expect(metadata[LogMetadata.Key.projectID] as? String == "canonical-project")
        #expect(metadata["vmId"] == nil)
        #expect(metadata["vm_id"] == nil)
        #expect(metadata["request-id"] == nil)
        #expect(metadata["projectId"] == nil)
    }

    @Test("A canonical spelling wins over its alias regardless of insertion order")
    func canonicalSpellingWinsWithinOneLayer() throws {
        var aliasFirst: Logger.Metadata = [:]
        aliasFirst["projectId"] = "legacy-value"
        aliasFirst[LogMetadata.Key.projectID] = "canonical-value"

        var canonicalFirst: Logger.Metadata = [:]
        canonicalFirst[LogMetadata.Key.projectID] = "canonical-value"
        canonicalFirst["projectId"] = "legacy-value"

        let aliasFirstDestination = RecordingLogDestination()
        let canonicalFirstDestination = RecordingLogDestination()
        makeHandler(destination: aliasFirstDestination).log(
            event: event(message: "same", metadata: aliasFirst))
        makeHandler(destination: canonicalFirstDestination).log(
            event: event(message: "same", metadata: canonicalFirst))

        let aliasFirstRecord = try #require(aliasFirstDestination.records.first)
        let canonicalFirstRecord = try #require(canonicalFirstDestination.records.first)
        #expect(aliasFirstRecord == canonicalFirstRecord)

        let record = try parseRecord(aliasFirstRecord)
        let metadata = try #require(record["metadata"] as? [String: Any])
        #expect(metadata[LogMetadata.Key.projectID] as? String == "canonical-value")
        #expect(metadata["projectId"] == nil)
    }

    @Test("Message, metadata, and complete records are bounded with explicit signals")
    func boundsAndSignalsTruncation() throws {
        let messageDestination = RecordingLogDestination()
        let oversizedMessage = String(repeating: "é", count: 5_000)
        makeHandler(destination: messageDestination).log(
            event: event(message: Logger.Message(stringLiteral: oversizedMessage)))

        let messageRecord = try parseRecord(try #require(messageDestination.records.first))
        let retainedMessage = try #require(messageRecord["message"] as? String)
        #expect(retainedMessage.utf8.count <= CustomLogHandler.maximumMessageBytes)
        let messageTruncation = try #require(messageRecord["truncation"] as? [String: Any])
        #expect(messageTruncation["message"] as? Bool == true)
        #expect(messageTruncation["message_limit_bytes"] as? Int == CustomLogHandler.maximumMessageBytes)

        var oversizedMetadata: Logger.Metadata = [:]
        for index in 0..<80 {
            oversizedMetadata[String(format: "field.%03d", index)] = .string(
                String(repeating: "x", count: 1_024))
        }
        let recordDestination = RecordingLogDestination()
        let escapingMessage = String(repeating: "\u{0000}", count: CustomLogHandler.maximumMessageBytes)
        makeHandler(destination: recordDestination).log(
            event: event(
                message: Logger.Message(stringLiteral: escapingMessage),
                metadata: oversizedMetadata))

        let data = try #require(recordDestination.records.first)
        let record = try parseRecord(data)
        #expect(data.count <= CustomLogHandler.maximumRecordBytes)
        #expect(record["truncated"] as? Bool == true)
        let truncation = try #require(record["truncation"] as? [String: Any])
        #expect(truncation["message"] as? Bool == true)
        #expect(truncation["metadata"] as? Bool == true)
        #expect(truncation["record"] as? Bool == true)
        #expect(truncation["metadata_limit_bytes"] as? Int == CustomLogHandler.maximumMetadataBytes)
        #expect(truncation["record_limit_bytes"] as? Int == CustomLogHandler.maximumRecordBytes)

        let retainedMetadata = try #require(record["metadata"] as? [String: Any])
        let encodedMetadata = try JSONSerialization.data(
            withJSONObject: retainedMetadata,
            options: [.sortedKeys])
        #expect(encodedMetadata.count <= CustomLogHandler.maximumMetadataBytes)
    }

    @Test("Handler instances sharing a destination serialize whole record writes")
    func concurrentWritesAreAtomic() async throws {
        let destination = RecordingLogDestination(delayWrites: true)
        let writer = SerializedLogRecordWriter { destination.write($0) }
        let handlers = (0..<8).map { index in
            CustomLogHandler(
                label: "handler-\(index)",
                output: writer,
                now: { Self.fixedDate })
        }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<128 {
                let handler = handlers[index % handlers.count]
                group.addTask {
                    handler.log(
                        event: event(
                            message: Logger.Message(stringLiteral: "record-\(index)"),
                            metadata: ["index": .stringConvertible(index)]))
                }
            }
        }

        #expect(destination.maximumConcurrentWrites == 1)
        #expect(destination.records.count == 128)

        var messages = Set<String>()
        for data in destination.records {
            let record = try parseRecord(data)
            messages.insert(try #require(record["message"] as? String))
        }
        #expect(messages == Set((0..<128).map { "record-\($0)" }))
    }
}
