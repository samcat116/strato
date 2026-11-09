import Foundation
import SwiftProtobuf

// MARK: - VM Status and Enums

public typealias VMStatus = Strato_Agent_V1_VMStatus
extension Strato_Agent_V1_VMStatus: Codable {

    // Transitional states: a control-plane-initiated operation is in flight and the
    // agent has not yet confirmed the terminal state. A reconciliation sweep moves
    // VMs stuck in these states to `.error` after a timeout.

    // Diagnostic states set by reconciliation, never by a normal operation.

    /// True while a requested operation is in flight and not yet confirmed by the agent.
    public var isTransitional: Bool {
        switch self {
        case .starting, .stopping:
            return true
        case .created, .running, .shutdown, .paused, .error, .unknown, .unspecified, .UNRECOGNIZED:
            return false
        }
    }

    /// Tolerant decoding: an unrecognized status string (e.g. from a control plane or
    /// agent running a different protocol version) decodes to `.unknown` instead of
    /// throwing, so version skew cannot crash message handling.
    public init(from decoder: Swift.Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VMStatus(rawValue: raw) ?? .unknown
    }

    public var protocolValue: String {
        switch self {
        case .created: return "Created"
        case .running: return "Running"
        case .shutdown: return "Shutdown"
        case .paused: return "Paused"
        case .starting: return "Starting"
        case .stopping: return "Stopping"
        case .error: return "Error"
        case .unknown: return "Unknown"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "Created": self = .created
        case "Running": self = .running
        case "Shutdown": self = .shutdown
        case "Paused": self = .paused
        case "Starting": self = .starting
        case "Stopping": self = .stopping
        case "Error": self = .error
        case "Unknown": self = .unknown
        default: return nil
        }
    }

    public static var knownCases: [Self] {
        [.created, .running, .shutdown, .paused, .starting, .stopping, .error, .unknown]
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

/// Whether the guest gets a framebuffer, and over which protocol (issue #566).
///
/// A graphics console does not replace the serial/virtio-console pair; it joins
/// them as a separate axis.
///
/// Decoding is strict for the same reason `DesiredVMStatus` is: a value this
/// build does not recognize must not silently degrade to "no display" on a VM
/// the API describes as having one. A future protocol (SPICE) arrives with its
/// own wire-version bump and gate, not by being tolerated here.
public typealias GraphicsMode = Strato_Agent_V1_GraphicsMode
extension Strato_Agent_V1_GraphicsMode: Codable {
    /// Headless — no display device, no framebuffer server. Today's behavior.
    ///
    /// Spelled `headless` rather than `none` deliberately. `graphics` is an
    /// Optional, and `spec.console?.graphics == .none` would compile against
    /// `Optional.none` — reading as "has a graphics mode of headless" while
    /// actually testing "the field is absent". The raw value stays `"None"`,
    /// so this is a source-level rename with no wire change.

    /// A VNC server on a Unix socket in the VM's directory, relayed to the
    /// browser by the agent. There is no RFB password: the socket's file mode
    /// and the control plane's `view_console` authorization are the security
    /// boundary, exactly as for the QMP and serial sockets beside it.

    public var protocolValue: String {
        switch self {
        case .headless: return "None"
        case .vnc: return "Vnc"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "None": self = .headless
        case "Vnc": self = .vnc
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.headless, .vnc] }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}
