import Foundation
import Logging
import StratoShared

/// Emits the agent's single metadata-only transport record for a wire frame.
///
/// Payload previews are deliberately unsupported. Adding a field here is the
/// review boundary for exposing more wire data to the privileged agent log.
public enum WireMessageLogger {
    public enum Direction: String, Sendable {
        case inbound
        case outbound
    }

    static let maximumIdentifierUTF8Bytes = 128

    /// Log one successfully encoded or decoded message without exposing its body.
    ///
    /// The caller supplies the already-typed message. This function must never
    /// encode or decode it merely to produce debug metadata.
    public static func log(
        message: any WebSocketMessage,
        direction: Direction,
        byteCount: Int,
        logger: Logger
    ) {
        guard logger.logLevel <= .debug else { return }

        var metadata: Logger.Metadata = [
            "byteCount": .string(String(byteCount)),
            "direction": .string(direction.rawValue),
            "type": .string(message.type.rawValue),
        ]
        addIdentifier(message.requestId, named: "requestId", to: &metadata)
        if let message = message as? any SessionCorrelatedWireMessage {
            addIdentifier(message.sessionId, named: "sessionId", to: &metadata)
        }
        if let message = message as? any SyncCorrelatedWireMessage {
            addIdentifier(message.syncId, named: "syncId", to: &metadata)
        }

        logger.debug("WebSocket message", metadata: metadata)
    }

    /// Report an envelope that could not be decoded without rendering the
    /// decoder error, which can quote attacker-controlled wire content.
    public static func logEnvelopeDecodingFailure(
        direction: Direction,
        byteCount: Int,
        logger: Logger
    ) {
        logger.error(
            "Failed to decode WebSocket envelope",
            metadata: [
                "byteCount": .string(String(byteCount)),
                "direction": .string(direction.rawValue),
            ])
    }

    /// Report a typed-message decode failure without accepting the underlying
    /// error as input, so its description cannot reintroduce payload content.
    public static func logMessageHandlingFailure(
        envelope: MessageEnvelope,
        logger: Logger
    ) {
        logger.error(
            "Failed to handle WebSocket message",
            metadata: [
                "direction": .string(Direction.inbound.rawValue),
                "type": .string(envelope.type.rawValue),
            ])
    }

    private static func addIdentifier(
        _ value: String?,
        named name: String,
        to metadata: inout Logger.Metadata
    ) {
        guard let value = sanitizedIdentifier(value) else { return }
        metadata[name] = .string(value)
    }

    private static func sanitizedIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }

        var fragments: [String] = []
        var byteCount = 0
        var truncated = false
        for scalar in value.unicodeScalars {
            let fragment = escaped(scalar)
            let fragmentByteCount = fragment.utf8.count
            guard byteCount + fragmentByteCount <= maximumIdentifierUTF8Bytes else {
                truncated = true
                break
            }
            fragments.append(fragment)
            byteCount += fragmentByteCount
        }

        if truncated {
            let marker = "..."
            while byteCount + marker.utf8.count > maximumIdentifierUTF8Bytes,
                let removed = fragments.popLast()
            {
                byteCount -= removed.utf8.count
            }
            fragments.append(marker)
        }
        return fragments.joined()
    }

    private static func escaped(_ scalar: Unicode.Scalar) -> String {
        switch scalar.value {
        case 0x09:
            return #"\t"#
        case 0x0A:
            return #"\n"#
        case 0x0D:
            return #"\r"#
        case 0x22:
            return #"\""#
        case 0x5C:
            return #"\\"#
        case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029:
            return #"\u{"# + String(scalar.value, radix: 16) + "}"
        default:
            return String(scalar)
        }
    }
}

/// Explicit correlation allowlists. Adding a conformance is the review boundary
/// for exposing another typed field to the privileged agent log.
private protocol SessionCorrelatedWireMessage {
    var sessionId: String { get }
}

extension ConsoleConnectMessage: SessionCorrelatedWireMessage {}
extension ConsoleDisconnectMessage: SessionCorrelatedWireMessage {}
extension ConsoleDataMessage: SessionCorrelatedWireMessage {}
extension ConsoleConnectedMessage: SessionCorrelatedWireMessage {}
extension ConsoleDisconnectedMessage: SessionCorrelatedWireMessage {}
extension GuestExecStartMessage: SessionCorrelatedWireMessage {}
extension GuestExecStartedMessage: SessionCorrelatedWireMessage {}
extension GuestExecInputMessage: SessionCorrelatedWireMessage {}
extension GuestExecOutputMessage: SessionCorrelatedWireMessage {}
extension GuestExecResizeMessage: SessionCorrelatedWireMessage {}
extension GuestExecExitMessage: SessionCorrelatedWireMessage {}
extension GuestExecCloseMessage: SessionCorrelatedWireMessage {}
extension GuestExecClosedMessage: SessionCorrelatedWireMessage {}

private protocol SyncCorrelatedWireMessage {
    var syncId: String { get }
}

extension DesiredStateMessage: SyncCorrelatedWireMessage {}
