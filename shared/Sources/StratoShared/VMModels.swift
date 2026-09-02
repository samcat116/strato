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

/// Whether the guest gets a framebuffer, and over which protocol (issue #566).
///
/// A graphics console does not replace the serial/virtio-console pair; it joins
/// them as a separate axis.
///
/// Decoding is strict for the same reason `DesiredVMStatus` is: a value this
/// build does not recognize must not silently degrade to "no display" on a VM
/// the API describes as having one. A future protocol (SPICE) arrives with its
/// own wire-version bump and gate, not by being tolerated here.
public enum GraphicsMode: String, Codable, CaseIterable, Sendable {
    /// Headless — no display device, no framebuffer server. Today's behavior.
    ///
    /// Spelled `headless` rather than `none` deliberately. `graphics` is an
    /// Optional, and `spec.console?.graphics == .none` would compile against
    /// `Optional.none` — reading as "has a graphics mode of headless" while
    /// actually testing "the field is absent". The raw value stays `"None"`,
    /// so this is a source-level rename with no wire change.
    case headless = "None"
    /// A VNC server on a Unix socket in the VM's directory, relayed to the
    /// browser by the agent. There is no RFB password: the socket's file mode
    /// and the control plane's `view_console` authorization are the security
    /// boundary, exactly as for the QMP and serial sockets beside it.
    case vnc = "Vnc"
}
