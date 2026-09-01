import Foundation
import InMemoryLogging
import Logging
import StratoShared
import Testing
@testable import StratoAgentCore

@Suite("Wire message logging")
struct WireMessageLoggingTests {
    @Test("Sensitive payloads never enter captured logs")
    func sensitivePayloadsNeverEnterCapturedLogs() throws {
        let workloadOutput = "WORKLOAD_OUTPUT_SENTINEL_STR_283"
        let consoleOutput = "CONSOLE_OUTPUT_SENTINEL_STR_283"
        let guestCommand = "GUEST_COMMAND_SENTINEL_STR_283"
        let guestEnvironmentSecret = "GUEST_ENV_SECRET_SENTINEL_STR_283"
        let guestInput = "GUEST_INPUT_SENTINEL_STR_283"
        let guestOutput = "GUEST_OUTPUT_SENTINEL_STR_283"
        let registryCredential = "REGISTRY_CREDENTIAL_SENTINEL_STR_283"

        let fixtures = try [
            fixture(
                SandboxLogMessage(
                    requestId: "request-sandbox-log",
                    sandboxId: "sandbox-1",
                    stream: "stdout",
                    message: workloadOutput),
                sentinels: [workloadOutput],
                expectedCorrelation: [:]),
            fixture(
                ConsoleDataMessage(
                    requestId: "request-console-data",
                    vmId: "vm-1",
                    sessionId: "console-session-1",
                    rawData: Data(consoleOutput.utf8)),
                sentinels: [consoleOutput],
                expectedCorrelation: ["sessionId": "console-session-1"]),
            fixture(
                GuestExecStartMessage(
                    requestId: "request-guest-command",
                    resourceKind: .virtualMachine,
                    resourceId: "vm-1",
                    sessionKind: .interactive,
                    sessionId: "exec-session-1",
                    command: ["/bin/sh", "-c", guestCommand],
                    env: ["TOKEN": guestEnvironmentSecret]),
                sentinels: [guestCommand, guestEnvironmentSecret],
                expectedCorrelation: ["sessionId": "exec-session-1"]),
            fixture(
                GuestExecInputMessage(
                    requestId: "request-guest-input",
                    sessionId: "exec-session-2",
                    rawData: Data(guestInput.utf8)),
                sentinels: [guestInput],
                expectedCorrelation: ["sessionId": "exec-session-2"]),
            fixture(
                GuestExecOutputMessage(
                    requestId: "request-guest-output",
                    sessionId: "exec-session-3",
                    stream: "stderr",
                    rawData: Data(guestOutput.utf8)),
                sentinels: [guestOutput],
                expectedCorrelation: ["sessionId": "exec-session-3"]),
            fixture(
                DesiredStateMessage(
                    requestId: "request-desired-state",
                    syncId: "sync-credential-1",
                    vms: [],
                    sandboxes: [
                        DesiredSandboxState(
                            sandboxId: UUID(),
                            spec: SandboxSpec(
                                image: "private.example/workload:latest",
                                cpus: 1,
                                memoryBytes: 256 << 20),
                            desiredStatus: .running,
                            generation: 1,
                            registryCredential: RegistryCredential(
                                registry: "private.example",
                                username: "strato",
                                password: registryCredential))
                    ]),
                sentinels: [registryCredential],
                expectedCorrelation: ["syncId": "sync-credential-1"]),
        ]

        for fixture in fixtures {
            let (logger, handler) = makeLogger()

            WireMessageLogger.log(
                message: fixture.message,
                direction: .outbound,
                byteCount: fixture.encodedFrame.count,
                logger: logger)

            let entries = handler.entries
            #expect(entries.count == 1, "one logical send must emit one primary record")
            let entry = try #require(entries.first)
            #expect(entry.level == .debug)
            #expect(entry.message == "WebSocket message")

            var expectedMetadata = fixture.expectedCorrelation
            expectedMetadata["direction"] = "outbound"
            expectedMetadata["type"] = fixture.envelope.type.rawValue
            expectedMetadata["byteCount"] = String(fixture.encodedFrame.count)
            expectedMetadata["requestId"] = fixture.requestId
            #expect(entry.metadata.keys.sorted() == expectedMetadata.keys.sorted())
            for (key, value) in expectedMetadata {
                #expect(stringMetadata(key, in: entry) == value)
            }

            let rendered = render(entry)
            for sentinel in fixture.sentinels {
                #expect(!rendered.contains(sentinel))
            }
            #expect(!rendered.contains(fixture.envelope.payload.base64EncodedString()))
            #expect(entry.metadata["payload"] == nil)
            #expect(entry.metadata["body"] == nil)
            #expect(entry.metadata["preview"] == nil)
        }
    }

    @Test("One record per direction retains type, correlation, and outer byte count")
    func oneRecordPerDirectionRetainsWireMetadata() throws {
        let message = GuestExecStartMessage(
            requestId: "request-42",
            resourceKind: .sandbox,
            resourceId: "sandbox-42",
            sessionKind: .interactive,
            sessionId: "session-42",
            command: ["/bin/true"])
        let envelope = try MessageEnvelope(message: message)
        let encodedFrame = try WireProtocol.makeEncoder().encode(envelope)
        let (logger, handler) = makeLogger()

        WireMessageLogger.log(
            message: message,
            direction: .outbound,
            byteCount: encodedFrame.count,
            logger: logger)
        WireMessageLogger.log(
            message: message,
            direction: .inbound,
            byteCount: encodedFrame.count,
            logger: logger)

        let entries = handler.entries
        #expect(entries.count == 2)
        #expect(entries.map { stringMetadata("direction", in: $0) } == ["outbound", "inbound"])
        for entry in entries {
            #expect(entry.level == .debug)
            #expect(entry.message == "WebSocket message")
            #expect(stringMetadata("type", in: entry) == MessageType.guestExecStart.rawValue)
            #expect(stringMetadata("requestId", in: entry) == "request-42")
            #expect(stringMetadata("sessionId", in: entry) == "session-42")
            #expect(stringMetadata("byteCount", in: entry) == String(encodedFrame.count))
            #expect(entry.metadata.keys.sorted() == ["byteCount", "direction", "requestId", "sessionId", "type"])
        }
    }

    @Test("Peer supplied identifiers are escaped and byte bounded")
    func identifiersAreEscapedAndBounded() throws {
        let requestId = "request\\\n\r\t" + String(repeating: "x", count: 256)
        let envelope = try MessageEnvelope(message: SuccessMessage(requestId: requestId))
        let encodedFrame = try WireProtocol.makeEncoder().encode(envelope)
        let (logger, handler) = makeLogger()

        WireMessageLogger.log(
            message: SuccessMessage(requestId: requestId),
            direction: .inbound,
            byteCount: encodedFrame.count,
            logger: logger)

        let entry = try #require(handler.entries.first)
        let loggedRequestId = try #require(stringMetadata("requestId", in: entry))
        #expect(!loggedRequestId.contains("\n"))
        #expect(!loggedRequestId.contains("\r"))
        #expect(!loggedRequestId.contains("\t"))
        #expect(loggedRequestId.contains(#"\n"#))
        #expect(loggedRequestId.contains(#"\r"#))
        #expect(loggedRequestId.contains(#"\t"#))
        #expect(loggedRequestId.utf8.count <= WireMessageLogger.maximumIdentifierUTF8Bytes)
        #expect(loggedRequestId.hasSuffix("..."))
    }

    @Test("Malformed wire content cannot re-enter logs through decoder errors")
    func malformedWireContentDoesNotEnterDecoderErrorLogs() throws {
        let sentinel = "MALFORMED_BODY_SENTINEL_STR_283\nsecond-line"
        let malformedBody = try WireProtocol.makeEncoder().encode(
            RawGuestExecStart(
                requestId: "request-malformed",
                timestamp: sentinel,
                resourceKind: "virtual_machine",
                resourceId: "vm-1",
                sessionId: "session-1",
                command: ["/bin/true"]))
        let encodedFrame = try WireProtocol.makeEncoder().encode(
            RawEnvelope(type: .guestExecStart, payload: malformedBody))
        let envelope = try WireProtocol.makeDecoder().decode(MessageEnvelope.self, from: encodedFrame)
        let (logger, handler) = makeLogger()

        do {
            _ = try envelope.decode(as: GuestExecStartMessage.self)
            Issue.record("malformed timestamp unexpectedly decoded")
        } catch {
            #expect(String(describing: error).contains("MALFORMED_BODY_SENTINEL_STR_283"))
            WireMessageLogger.logMessageHandlingFailure(envelope: envelope, logger: logger)
        }

        let invalidOuterFrame = Data(
            #"{"type":"guest_exec_start","payload":"MALFORMED_OUTER_SENTINEL_STR_283"}"#.utf8)
        do {
            _ = try WireProtocol.makeDecoder().decode(MessageEnvelope.self, from: invalidOuterFrame)
            Issue.record("malformed envelope unexpectedly decoded")
        } catch {
            WireMessageLogger.logEnvelopeDecodingFailure(
                direction: .inbound,
                byteCount: invalidOuterFrame.count,
                logger: logger)
        }

        let entries = handler.entries
        #expect(entries.count == 2)
        #expect(
            entries.map(\.message) == [
                "Failed to handle WebSocket message",
                "Failed to decode WebSocket envelope",
            ])
        let rendered = entries.map(render).joined(separator: "\n")
        #expect(!rendered.contains("MALFORMED_BODY_SENTINEL_STR_283"))
        #expect(!rendered.contains("MALFORMED_OUTER_SENTINEL_STR_283"))
        #expect(!rendered.contains(envelope.payload.base64EncodedString()))
        #expect(entries[0].metadata.keys.sorted() == ["direction", "type"])
        #expect(entries[1].metadata.keys.sorted() == ["byteCount", "direction"])
    }

    @Test("Metadata logging never encodes or decodes the message payload")
    func metadataLoggingDoesNotCodePayload() throws {
        let message = CodingTrapMessage(
            requestId: "request-no-coding",
            secret: "CODING_TRAP_SECRET_STR_283")
        let (logger, handler) = makeLogger()

        WireMessageLogger.log(
            message: message,
            direction: .outbound,
            byteCount: 16 << 20,
            logger: logger)

        let entry = try #require(handler.entries.first)
        #expect(handler.entries.count == 1)
        #expect(stringMetadata("requestId", in: entry) == "request-no-coding")
        #expect(stringMetadata("byteCount", in: entry) == String(16 << 20))
        #expect(!render(entry).contains("CODING_TRAP_SECRET_STR_283"))
    }

    private struct Fixture {
        let message: any WebSocketMessage
        let envelope: MessageEnvelope
        let encodedFrame: Data
        let requestId: String
        let sentinels: [String]
        let expectedCorrelation: [String: String]
    }

    private struct RawEnvelope: Encodable {
        let type: MessageType
        let payload: Data
    }

    private struct RawGuestExecStart: Encodable {
        let requestId: String
        let timestamp: String
        let resourceKind: String
        let resourceId: String
        let sessionId: String
        let command: [String]
    }

    private struct CodingTrapMessage: WebSocketMessage {
        var type: MessageType { .sandboxLog }
        let requestId: String
        let timestamp = Date()
        let secret: String

        init(requestId: String, secret: String) {
            self.requestId = requestId
            self.secret = secret
        }

        init(from decoder: Decoder) throws {
            Issue.record("wire metadata logging unexpectedly decoded the message")
            throw CodingTrapError.unexpectedCoding
        }

        func encode(to encoder: Encoder) throws {
            Issue.record("wire metadata logging unexpectedly encoded the message")
            throw CodingTrapError.unexpectedCoding
        }
    }

    private enum CodingTrapError: Error {
        case unexpectedCoding
    }

    private func fixture<T: WebSocketMessage>(
        _ message: T,
        sentinels: [String],
        expectedCorrelation: [String: String]
    ) throws -> Fixture {
        let envelope = try MessageEnvelope(message: message)
        return try Fixture(
            message: message,
            envelope: envelope,
            encodedFrame: WireProtocol.makeEncoder().encode(envelope),
            requestId: message.requestId,
            sentinels: sentinels,
            expectedCorrelation: expectedCorrelation)
    }

    private func makeLogger() -> (Logger, InMemoryLogHandler) {
        let handler = InMemoryLogHandler()
        var logger = Logger(label: "wire-message-logging-tests") { _ in handler }
        logger.logLevel = .trace
        return (logger, handler)
    }

    private func stringMetadata(_ key: String, in entry: InMemoryLogHandler.Entry) -> String? {
        guard case .string(let value) = entry.metadata[key] else { return nil }
        return value
    }

    private func render(_ entry: InMemoryLogHandler.Entry) -> String {
        let metadata = entry.metadata.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return "\(entry.message) \(metadata)"
    }
}
