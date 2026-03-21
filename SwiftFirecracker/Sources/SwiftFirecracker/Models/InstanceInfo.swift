import Foundation

/// Instance information response from Firecracker
/// Maps to GET / API endpoint
public struct InstanceInfo: Codable, Sendable {
    /// Application name (always "Firecracker")
    public let appName: String

    /// Unique identifier for this Firecracker instance
    public let id: String

    /// Current state of the microVM
    public let state: InstanceState

    /// Firecracker version
    public let vmlinuxVersion: String

    /// Build information
    public let vmlinuxBuildTime: String?

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case id
        case state
        case vmlinuxVersion = "vmm_version"
        case vmlinuxBuildTime = "vmm_build_time"
    }
}

/// Possible states of a Firecracker microVM
public enum InstanceState: String, Codable, Sendable {
    /// VM is not yet started
    case notStarted = "Not started"

    /// VM is running
    case running = "Running"

    /// VM is paused
    case paused = "Paused"
}

/// VM action request
/// Maps to PUT /actions API endpoint
public struct VMAction: Codable, Sendable {
    /// Type of action to perform
    public let actionType: VMActionType

    enum CodingKeys: String, CodingKey {
        case actionType = "action_type"
    }

    public init(actionType: VMActionType) {
        self.actionType = actionType
    }
}

/// Types of actions that can be performed on a VM
public enum VMActionType: String, Codable, Sendable {
    /// Start the VM (begins execution)
    case instanceStart = "InstanceStart"

    /// Send Ctrl+Alt+Del to the VM
    case sendCtrlAltDel = "SendCtrlAltDel"

    /// Flush metrics to the metrics file
    case flushMetrics = "FlushMetrics"
}

/// VM state change request
/// Maps to PATCH /vm API endpoint
public struct VMStateChange: Codable, Sendable {
    /// Target state: "Paused" or "Resumed"
    public let state: String

    public init(state: VMTargetState) {
        self.state = state.rawValue
    }
}

/// Target states for PATCH /vm
public enum VMTargetState: String, Sendable {
    case paused = "Paused"
    case resumed = "Resumed"
}

/// Error response from Firecracker API
public struct FirecrackerAPIError: Codable, Sendable {
    /// Error fault message
    public let faultMessage: String

    enum CodingKeys: String, CodingKey {
        case faultMessage = "fault_message"
    }
}
