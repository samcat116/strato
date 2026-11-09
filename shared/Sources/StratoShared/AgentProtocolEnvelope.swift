import Foundation
import SwiftProtobuf

public typealias MessageEnvelope = Strato_Agent_V1_AgentEnvelope

public enum AgentProtocolDecodeError: Error, Sendable {
    case missingBody
    case unexpectedMessage
    case invalidField
    case malformedMessage
}

extension Strato_Agent_V1_AgentEnvelope {
    public init<T: WebSocketMessage>(message: T) throws {
        self.init()
        switch message {
        case let message as AgentRegisterMessage: body = .agentRegisterMessage(message)
        case let message as AgentHeartbeatMessage: body = .agentHeartbeatMessage(message)
        case let message as AgentUnregisterMessage: body = .agentUnregisterMessage(message)
        case let message as AgentRegisterResponseMessage: body = .agentRegisterResponseMessage(message)
        case let message as SuccessMessage: body = .successMessage(message)
        case let message as ErrorMessage: body = .errorMessage(message)
        case let message as ConsoleConnectMessage: body = .consoleConnectMessage(message)
        case let message as ConsoleDisconnectMessage: body = .consoleDisconnectMessage(message)
        case let message as ConsoleDataMessage: body = .consoleDataMessage(message)
        case let message as ConsoleConnectedMessage: body = .consoleConnectedMessage(message)
        case let message as ConsoleDisconnectedMessage: body = .consoleDisconnectedMessage(message)
        case let message as VMLogMessage: body = .vmLogMessage(message)
        case let message as GuestExecStartMessage: body = .guestExecStartMessage(message)
        case let message as GuestExecRecordedStateMessage: body = .guestExecRecordedStateMessage(message)
        case let message as GuestExecRecordedAckMessage: body = .guestExecRecordedAckMessage(message)
        case let message as GuestExecStartedMessage: body = .guestExecStartedMessage(message)
        case let message as GuestExecInputMessage: body = .guestExecInputMessage(message)
        case let message as GuestExecOutputMessage: body = .guestExecOutputMessage(message)
        case let message as GuestExecResizeMessage: body = .guestExecResizeMessage(message)
        case let message as GuestExecExitMessage: body = .guestExecExitMessage(message)
        case let message as GuestExecCloseMessage: body = .guestExecCloseMessage(message)
        case let message as GuestExecClosedMessage: body = .guestExecClosedMessage(message)
        case let message as SandboxLogMessage: body = .sandboxLogMessage(message)
        case let message as DesiredStateMessage: body = .desiredStateMessage(message)
        case let message as ObservedStateReport: body = .observedStateReport(message)
        default: throw AgentProtocolDecodeError.unexpectedMessage
        }
    }

    public var type: MessageType {
        switch body {
        case .agentRegisterMessage: return .agentRegister
        case .agentHeartbeatMessage: return .agentHeartbeat
        case .agentUnregisterMessage: return .agentUnregister
        case .agentRegisterResponseMessage: return .agentRegisterResponse
        case .successMessage: return .success
        case .errorMessage: return .error
        case .consoleConnectMessage: return .consoleConnect
        case .consoleDisconnectMessage: return .consoleDisconnect
        case .consoleDataMessage: return .consoleData
        case .consoleConnectedMessage: return .consoleConnected
        case .consoleDisconnectedMessage: return .consoleDisconnected
        case .vmLogMessage: return .vmLog
        case .guestExecStartMessage: return .guestExecStart
        case .guestExecRecordedStateMessage: return .guestExecRecordedState
        case .guestExecRecordedAckMessage: return .guestExecRecordedAck
        case .guestExecStartedMessage: return .guestExecStarted
        case .guestExecInputMessage: return .guestExecInput
        case .guestExecOutputMessage: return .guestExecOutput
        case .guestExecResizeMessage: return .guestExecResize
        case .guestExecExitMessage: return .guestExecExit
        case .guestExecCloseMessage: return .guestExecClose
        case .guestExecClosedMessage: return .guestExecClosed
        case .sandboxLogMessage: return .sandboxLog
        case .desiredStateMessage: return .desiredState
        case .observedStateReport: return .observedState
        case nil: return .error
        }
    }

    public var requirements: Strato_Agent_V1_ProtocolRequirements {
        .with { $0.capabilities = requiredCapabilities }
    }

    public func decode<T: WebSocketMessage>(as messageType: T.Type) throws -> T {
        let message: any WebSocketMessage
        switch body {
        case .agentRegisterMessage(let value): message = value
        case .agentHeartbeatMessage(let value): message = value
        case .agentUnregisterMessage(let value): message = value
        case .agentRegisterResponseMessage(let value): message = value
        case .successMessage(let value): message = value
        case .errorMessage(let value): message = value
        case .consoleConnectMessage(let value): message = value
        case .consoleDisconnectMessage(let value): message = value
        case .consoleDataMessage(let value): message = value
        case .consoleConnectedMessage(let value): message = value
        case .consoleDisconnectedMessage(let value): message = value
        case .vmLogMessage(let value): message = value
        case .guestExecStartMessage(let value): message = value
        case .guestExecRecordedStateMessage(let value): message = value
        case .guestExecRecordedAckMessage(let value): message = value
        case .guestExecStartedMessage(let value): message = value
        case .guestExecInputMessage(let value): message = value
        case .guestExecOutputMessage(let value): message = value
        case .guestExecResizeMessage(let value): message = value
        case .guestExecExitMessage(let value): message = value
        case .guestExecCloseMessage(let value): message = value
        case .guestExecClosedMessage(let value): message = value
        case .sandboxLogMessage(let value): message = value
        case .desiredStateMessage(let value): message = value
        case .observedStateReport(let value): message = value
        case nil: throw AgentProtocolDecodeError.missingBody
        }
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
        try canonical.normalizeProtocolIdentifiers()
        return try canonical.serializedData()
    }

    public static func decodeEnvelope(_ bytes: Data) throws -> MessageEnvelope {
        var envelope: MessageEnvelope
        do { envelope = try MessageEnvelope(serializedBytes: bytes) } catch {
            throw AgentProtocolDecodeError.malformedMessage
        }
        try envelope.validateProtocol()
        try envelope.normalizeProtocolIdentifiers()
        return envelope
    }
}

extension Strato_Agent_V1_AgentRegisterMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_AgentHeartbeatMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_AgentUnregisterMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_AgentRegisterResponseMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_SuccessMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_ErrorMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_ConsoleConnectMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_ConsoleDisconnectMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_ConsoleDataMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_ConsoleConnectedMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_ConsoleDisconnectedMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_VMLogMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_GuestExecStartMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_GuestExecRecordedStateMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_GuestExecRecordedAckMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_GuestExecStartedMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_GuestExecInputMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_GuestExecOutputMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_GuestExecResizeMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_GuestExecExitMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_GuestExecCloseMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_GuestExecClosedMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_SandboxLogMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_DesiredStateMessage {
    public var requestId: String { requestID }
}

extension Strato_Agent_V1_ObservedStateReport {
    public var requestId: String { requestID }
}

extension UUID {
    /// Reject malformed protocol identifiers before using them as durable keys.
    public init(protocolString: String) throws {
        guard let value = UUID(uuidString: protocolString) else { throw AgentProtocolDecodeError.invalidField }
        self = value
    }
}
