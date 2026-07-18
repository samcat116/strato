import Foundation

// MARK: - VM Status and Enums

public enum VMStatus: String, Codable, CaseIterable, Sendable {
    case created = "Created"
    case running = "Running"
    case shutdown = "Shutdown"
    case paused = "Paused"

    // Transitional states: a control-plane-initiated operation is in flight and the
    // agent has not yet confirmed the terminal state. A reconciliation sweep moves
    // VMs stuck in these states to `.error` after a timeout.
    case starting = "Starting"
    case stopping = "Stopping"

    // Diagnostic states set by reconciliation, never by a normal operation.
    case error = "Error"  // operation failed, timed out, or the VM vanished from its agent
    case unknown = "Unknown"  // the VM's true state could not be determined

    /// True while a requested operation is in flight and not yet confirmed by the agent.
    public var isTransitional: Bool {
        switch self {
        case .starting, .stopping:
            return true
        case .created, .running, .shutdown, .paused, .error, .unknown:
            return false
        }
    }

    /// Tolerant decoding: an unrecognized status string (e.g. from a control plane or
    /// agent running a different protocol version) decodes to `.unknown` instead of
    /// throwing, so version skew cannot crash message handling.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VMStatus(rawValue: raw) ?? .unknown
    }
}

public enum ConsoleMode: String, Codable, CaseIterable, Sendable {
    case off = "Off"
    case pty = "Pty"
    case tty = "Tty"
    case file = "File"
    case socket = "Socket"
    case null = "Null"
}
