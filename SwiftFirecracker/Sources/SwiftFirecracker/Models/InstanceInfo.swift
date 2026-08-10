import Foundation

/// Instance information response from Firecracker
/// Maps to GET / API endpoint
public struct InstanceInfo: Codable, Sendable {
    /// Application name (always "Firecracker")
    let appName: String

    /// Unique identifier for this Firecracker instance
    let id: String

    /// Current state of the microVM
    public let state: InstanceState

    /// Firecracker version
    public let vmlinuxVersion: String

    /// Build information
    let vmlinuxBuildTime: String?

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
struct VMAction: Codable, Sendable {
    /// Type of action to perform
    let actionType: VMActionType

    enum CodingKeys: String, CodingKey {
        case actionType = "action_type"
    }

    init(actionType: VMActionType) {
        self.actionType = actionType
    }
}

/// Types of actions that can be performed on a VM
enum VMActionType: String, Codable, Sendable {
    /// Start the VM (begins execution)
    case instanceStart = "InstanceStart"

    /// Send Ctrl+Alt+Del to the VM
    case sendCtrlAltDel = "SendCtrlAltDel"

    /// Flush metrics to the metrics file
    case flushMetrics = "FlushMetrics"
}

/// VM state change request
/// Maps to PATCH /vm API endpoint
struct VMStateChange: Codable, Sendable {
    /// Target state: "Paused" or "Resumed"
    let state: String

    init(state: VMTargetState) {
        self.state = state.rawValue
    }
}

/// Target states for PATCH /vm
enum VMTargetState: String, Sendable {
    case paused = "Paused"
    case resumed = "Resumed"
}

/// Error response from Firecracker API
struct FirecrackerAPIError: Codable, Sendable {
    /// Error fault message
    let faultMessage: String

    enum CodingKeys: String, CodingKey {
        case faultMessage = "fault_message"
    }
}
