import Foundation
import SwiftProtobuf

public typealias MessageEnvelope = Strato_Agent_V1_AgentEnvelope

public enum AgentProtocolDecodeError: Error, Sendable {
    case missingBody
    case unexpectedMessage
    case invalidField
    case malformedMessage
}

// `init(message:)`, `type`, and `bodyMessage` are generated in
// Generated/AgentProtocolEnvelopeDispatch.swift from the schema's `body` oneof.
extension Strato_Agent_V1_AgentEnvelope {
    public var requirements: Strato_Agent_V1_ProtocolRequirements {
        .with { $0.capabilities = requiredCapabilities }
    }

    public func decode<T: WebSocketMessage>(as messageType: T.Type) throws -> T {
        guard let message = bodyMessage else { throw AgentProtocolDecodeError.missingBody }
        guard let typed = message as? T else { throw AgentProtocolDecodeError.unexpectedMessage }
        return typed
    }
}

extension WireProtocol {
    public static func encodeEnvelope<T: WebSocketMessage>(_ message: T) throws -> Data {
        try encodeEnvelope(MessageEnvelope(message: message))
    }

    public static func encodeEnvelope(_ envelope: MessageEnvelope) throws -> Data {
        try envelope.validateProtocol()
        var canonical = envelope
        try canonical.normalizeProtocolValues()
        return try canonical.serializedData()
    }

    public static func decodeEnvelope(_ bytes: Data) throws -> MessageEnvelope {
        var envelope: MessageEnvelope
        do { envelope = try MessageEnvelope(serializedBytes: bytes) } catch {
            throw AgentProtocolDecodeError.malformedMessage
        }
        try envelope.validateProtocol()
        try envelope.normalizeProtocolValues()
        return envelope
    }
}

extension UUID {
    /// Reject malformed protocol identifiers before using them as durable keys.
    public init(protocolString: String) throws {
        guard let value = UUID(uuidString: protocolString) else { throw AgentProtocolDecodeError.invalidField }
        self = value
    }
}
