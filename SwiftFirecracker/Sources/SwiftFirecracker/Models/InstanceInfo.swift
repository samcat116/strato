import Foundation

/// Instance information response from Firecracker
/// Maps to GET / API endpoint
public struct InstanceInfo: Codable, Sendable {
    public let state: InstanceState

    public let vmlinuxVersion: String

    enum CodingKeys: String, CodingKey {
        case state
        case vmlinuxVersion = "vmm_version"
    }
}

/// Possible states of a Firecracker microVM
public enum InstanceState: String, Codable, Sendable {
    case notStarted = "Not started"

    case running = "Running"

    case paused = "Paused"
}

/// VM action request
/// Maps to PUT /actions API endpoint
struct VMAction: Codable, Sendable {
    let actionType: VMActionType

    enum CodingKeys: String, CodingKey {
        case actionType = "action_type"
    }

    init(actionType: VMActionType) {
        self.actionType = actionType
    }
}

enum VMActionType: String, Codable, Sendable {
    case instanceStart = "InstanceStart"

    case sendCtrlAltDel = "SendCtrlAltDel"
}

/// VM state change request
/// Maps to PATCH /vm API endpoint
struct VMStateChange: Codable, Sendable {
    let state: String

    init(state: VMTargetState) {
        self.state = state.rawValue
    }
}

enum VMTargetState: String, Sendable {
    case paused = "Paused"
    case resumed = "Resumed"
}

/// Error response from Firecracker API
struct FirecrackerAPIError: Codable, Sendable {
    let faultMessage: String

    enum CodingKeys: String, CodingKey {
        case faultMessage = "fault_message"
    }
}
