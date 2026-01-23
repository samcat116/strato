import Foundation

// MARK: - WebSocket Message Types

public enum MessageType: String, Codable, Sendable {
    // Agent registration and heartbeat
    case agentRegister = "agent_register"
    case agentRegisterResponse = "agent_register_response"
    case agentHeartbeat = "agent_heartbeat"
    case agentUnregister = "agent_unregister"
    
    // VM lifecycle operations
    case vmCreate = "vm_create"
    case vmBoot = "vm_boot" 
    case vmShutdown = "vm_shutdown"
    case vmReboot = "vm_reboot"
    case vmPause = "vm_pause"
    case vmResume = "vm_resume"
    case vmDelete = "vm_delete"
    
    // VM information queries
    case vmInfo = "vm_info"
    case vmStatus = "vm_status"
    case vmCounters = "vm_counters"
    
    // Network management operations
    case networkCreate = "network_create"
    case networkDelete = "network_delete"
    case networkList = "network_list"
    case networkInfo = "network_info"
    case networkAttach = "network_attach"
    case networkDetach = "network_detach"
    
    // Image operations
    case imageInfo = "image_info"
    case imageInfoResponse = "image_info_response"

    // Volume operations (QEMU only - not supported for Firecracker)
    case volumeCreate = "volume_create"
    case volumeDelete = "volume_delete"
    case volumeAttach = "volume_attach"
    case volumeDetach = "volume_detach"
    case volumeResize = "volume_resize"
    case volumeSnapshot = "volume_snapshot"
    case volumeClone = "volume_clone"
    case volumeInfo = "volume_info"
    case volumeStatus = "volume_status"

    // Console operations
    case consoleConnect = "console_connect"
    case consoleDisconnect = "console_disconnect"
    case consoleData = "console_data"
    case consoleConnected = "console_connected"
    case consoleDisconnected = "console_disconnected"

    // Responses
    case success = "success"
    case error = "error"
    case statusUpdate = "status_update"

    // VM Logs
    case vmLog = "vm_log"
}

// MARK: - Base Message Protocol

public protocol WebSocketMessage: Codable, Sendable {
    var type: MessageType { get }
    var requestId: String { get }
    var timestamp: Date { get }
}

// MARK: - Agent Messages

public struct AgentRegisterMessage: WebSocketMessage {
    public var type: MessageType { .agentRegister }
    public let requestId: String
    public let timestamp: Date
    public let agentId: String
    public let hostname: String
    public let version: String
    public let capabilities: [String]
    public let resources: AgentResources
    public let hypervisorType: HypervisorType

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String,
        hostname: String,
        version: String,
        capabilities: [String],
        resources: AgentResources,
        hypervisorType: HypervisorType = .qemu
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.hostname = hostname
        self.version = version
        self.capabilities = capabilities
        self.resources = resources
        self.hypervisorType = hypervisorType
    }
}

public struct AgentHeartbeatMessage: WebSocketMessage {
    public var type: MessageType { .agentHeartbeat }
    public let requestId: String
    public let timestamp: Date
    public let agentId: String
    public let resources: AgentResources
    public let runningVMs: [String] // VM IDs
    
    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String,
        resources: AgentResources,
        runningVMs: [String]
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.resources = resources
        self.runningVMs = runningVMs
    }
}

public struct AgentUnregisterMessage: WebSocketMessage {
    public var type: MessageType { .agentUnregister }
    public let requestId: String
    public let timestamp: Date
    public let agentId: String
    public let reason: String?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String,
        reason: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.reason = reason
    }
}

public struct AgentRegisterResponseMessage: WebSocketMessage {
    public let type: MessageType = .agentRegisterResponse
    public let requestId: String
    public let timestamp: Date
    public let agentId: String  // The database UUID assigned to this agent
    public let name: String     // The human-readable name

    public init(
        requestId: String,
        timestamp: Date = Date(),
        agentId: String,
        name: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.name = name
    }
}

public struct AgentResources: Codable, Sendable {
    public let totalCPU: Int
    public let availableCPU: Int
    public let totalMemory: Int64
    public let availableMemory: Int64
    public let totalDisk: Int64
    public let availableDisk: Int64
    
    public init(
        totalCPU: Int,
        availableCPU: Int,
        totalMemory: Int64,
        availableMemory: Int64,
        totalDisk: Int64,
        availableDisk: Int64
    ) {
        self.totalCPU = totalCPU
        self.availableCPU = availableCPU
        self.totalMemory = totalMemory
        self.availableMemory = availableMemory
        self.totalDisk = totalDisk
        self.availableDisk = availableDisk
    }
}

// MARK: - VM Operation Messages

public struct VMCreateMessage: WebSocketMessage {
    public var type: MessageType { .vmCreate }
    public let requestId: String
    public let timestamp: Date
    public let vmData: VMData
    public let vmConfig: VmConfig
    public let imageInfo: ImageInfo?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmData: VMData,
        vmConfig: VmConfig,
        imageInfo: ImageInfo? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmData = vmData
        self.vmConfig = vmConfig
        self.imageInfo = imageInfo
    }
}

// MARK: - Image Information

/// Contains information for the agent to download and cache an image
public struct ImageInfo: Codable, Sendable {
    public let imageId: UUID
    public let projectId: UUID
    public let filename: String
    public let checksum: String
    public let size: Int64
    public let downloadURL: String
    /// When the signed download URL expires (optional, for agent awareness)
    public let expiresAt: Date?

    public init(
        imageId: UUID,
        projectId: UUID,
        filename: String,
        checksum: String,
        size: Int64,
        downloadURL: String,
        expiresAt: Date? = nil
    ) {
        self.imageId = imageId
        self.projectId = projectId
        self.filename = filename
        self.checksum = checksum
        self.size = size
        self.downloadURL = downloadURL
        self.expiresAt = expiresAt
    }
}

public struct ImageInfoRequestMessage: WebSocketMessage {
    public var type: MessageType { .imageInfo }
    public let requestId: String
    public let timestamp: Date
    public let imageId: UUID

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        imageId: UUID
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.imageId = imageId
    }
}

public struct ImageInfoResponseMessage: WebSocketMessage {
    public var type: MessageType { .imageInfoResponse }
    public let requestId: String
    public let timestamp: Date
    public let imageInfo: ImageInfo?
    public let error: String?

    public init(
        requestId: String,
        timestamp: Date = Date(),
        imageInfo: ImageInfo? = nil,
        error: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.imageInfo = imageInfo
        self.error = error
    }
}

public struct VMOperationMessage: WebSocketMessage {
    public let type: MessageType
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    
    public init(
        type: MessageType,
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String
    ) {
        self.type = type
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
    }
}

public struct VMInfoRequestMessage: WebSocketMessage {
    public var type: MessageType { .vmInfo }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    
    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
    }
}

// MARK: - Response Messages

public struct SuccessMessage: WebSocketMessage {
    public var type: MessageType { .success }
    public let requestId: String
    public let timestamp: Date
    public let message: String?
    public let data: AnyCodableValue?
    
    public init(
        requestId: String,
        timestamp: Date = Date(),
        message: String? = nil,
        data: AnyCodableValue? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.message = message
        self.data = data
    }
}

public struct ErrorMessage: WebSocketMessage {
    public var type: MessageType { .error }
    public let requestId: String
    public let timestamp: Date
    public let error: String
    public let details: String?
    
    public init(
        requestId: String,
        timestamp: Date = Date(),
        error: String,
        details: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.error = error
        self.details = details
    }
}

public struct StatusUpdateMessage: WebSocketMessage {
    public var type: MessageType { .statusUpdate }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let status: VMStatus
    public let details: String?
    
    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        status: VMStatus,
        details: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.status = status
        self.details = details
    }
}

// MARK: - Any Codable Value for Dynamic Data

public struct AnyCodableValue: Codable, Sendable {
    public let value: CodableValue
    
    public init<T: Codable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        self.value = try JSONDecoder().decode(CodableValue.self, from: data)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try container.decode(CodableValue.self)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
    
    public func decode<T: Codable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }
}

public enum CodableValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([CodableValue])
    case object([String: CodableValue])
    case null
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let arrayValue = try? container.decode([CodableValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: CodableValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.typeMismatch(CodableValue.self, 
                DecodingError.Context(codingPath: decoder.codingPath, 
                                    debugDescription: "Unsupported type"))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

// MARK: - Network Operation Messages

public struct NetworkCreateMessage: WebSocketMessage {
    public var type: MessageType { .networkCreate }
    public let requestId: String
    public let timestamp: Date
    public let networkName: String
    public let subnet: String
    public let gateway: String?
    public let vlanId: Int?
    public let dhcpEnabled: Bool
    public let dnsServers: [String]
    
    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        networkName: String,
        subnet: String,
        gateway: String? = nil,
        vlanId: Int? = nil,
        dhcpEnabled: Bool = true,
        dnsServers: [String] = []
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.networkName = networkName
        self.subnet = subnet
        self.gateway = gateway
        self.vlanId = vlanId
        self.dhcpEnabled = dhcpEnabled
        self.dnsServers = dnsServers
    }
}

public struct NetworkDeleteMessage: WebSocketMessage {
    public var type: MessageType { .networkDelete }
    public let requestId: String
    public let timestamp: Date
    public let networkName: String
    
    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        networkName: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.networkName = networkName
    }
}

public struct NetworkListMessage: WebSocketMessage {
    public var type: MessageType { .networkList }
    public let requestId: String
    public let timestamp: Date
    
    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date()
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
    }
}

public struct NetworkInfoMessage: WebSocketMessage {
    public var type: MessageType { .networkInfo }
    public let requestId: String
    public let timestamp: Date
    public let networkName: String
    
    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        networkName: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.networkName = networkName
    }
}

public struct NetworkAttachMessage: WebSocketMessage {
    public var type: MessageType { .networkAttach }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let networkName: String
    public let config: VMNetworkConfig?
    
    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        networkName: String,
        config: VMNetworkConfig? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.networkName = networkName
        self.config = config
    }
}

public struct NetworkDetachMessage: WebSocketMessage {
    public var type: MessageType { .networkDetach }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    
    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
    }
}

// MARK: - Console Operation Messages

public struct ConsoleConnectMessage: WebSocketMessage {
    public var type: MessageType { .consoleConnect }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let sessionId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.sessionId = sessionId
    }
}

public struct ConsoleDisconnectMessage: WebSocketMessage {
    public var type: MessageType { .consoleDisconnect }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let sessionId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.sessionId = sessionId
    }
}

public struct ConsoleDataMessage: WebSocketMessage {
    public var type: MessageType { .consoleData }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let sessionId: String
    public let data: String  // Base64 encoded bytes

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String,
        data: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.sessionId = sessionId
        self.data = data
    }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String,
        rawData: Data
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.sessionId = sessionId
        self.data = rawData.base64EncodedString()
    }

    public var rawData: Data? {
        Data(base64Encoded: data)
    }
}

public struct ConsoleConnectedMessage: WebSocketMessage {
    public var type: MessageType { .consoleConnected }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let sessionId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.sessionId = sessionId
    }
}

public struct ConsoleDisconnectedMessage: WebSocketMessage {
    public var type: MessageType { .consoleDisconnected }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let sessionId: String
    public let reason: String?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        sessionId: String,
        reason: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.sessionId = sessionId
        self.reason = reason
    }
}

// MARK: - Volume Operation Messages (QEMU only)

/// Message to create a new volume on an agent
public struct VolumeCreateMessage: WebSocketMessage {
    public var type: MessageType { .volumeCreate }
    public let requestId: String
    public let timestamp: Date
    public let volumeId: String
    public let size: Int64           // Size in bytes
    public let format: String        // "qcow2" or "raw"
    public let sourceImageInfo: ImageInfo?  // For volumes created from images
    public let sourceVolumePath: String?    // For cloning existing volumes

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        volumeId: String,
        size: Int64,
        format: String = "qcow2",
        sourceImageInfo: ImageInfo? = nil,
        sourceVolumePath: String? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.volumeId = volumeId
        self.size = size
        self.format = format
        self.sourceImageInfo = sourceImageInfo
        self.sourceVolumePath = sourceVolumePath
    }
}

/// Message to delete a volume from an agent
public struct VolumeDeleteMessage: WebSocketMessage {
    public var type: MessageType { .volumeDelete }
    public let requestId: String
    public let timestamp: Date
    public let volumeId: String
    public let volumePath: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        volumeId: String,
        volumePath: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.volumeId = volumeId
        self.volumePath = volumePath
    }
}

/// Message to attach a volume to a running VM (hot-plug)
public struct VolumeAttachMessage: WebSocketMessage {
    public var type: MessageType { .volumeAttach }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let volumeId: String
    public let volumePath: String
    public let deviceName: String    // e.g., "disk1", "disk2"
    public let readonly: Bool

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        volumeId: String,
        volumePath: String,
        deviceName: String,
        readonly: Bool = false
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.volumeId = volumeId
        self.volumePath = volumePath
        self.deviceName = deviceName
        self.readonly = readonly
    }
}

/// Message to detach a volume from a running VM (hot-unplug)
public struct VolumeDetachMessage: WebSocketMessage {
    public var type: MessageType { .volumeDetach }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let volumeId: String
    public let deviceName: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        volumeId: String,
        deviceName: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.volumeId = volumeId
        self.deviceName = deviceName
    }
}

/// Message to resize a volume (must be detached)
public struct VolumeResizeMessage: WebSocketMessage {
    public var type: MessageType { .volumeResize }
    public let requestId: String
    public let timestamp: Date
    public let volumeId: String
    public let volumePath: String
    public let newSize: Int64        // New size in bytes

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        volumeId: String,
        volumePath: String,
        newSize: Int64
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.volumeId = volumeId
        self.volumePath = volumePath
        self.newSize = newSize
    }
}

/// Message to create a snapshot of a volume
public struct VolumeSnapshotMessage: WebSocketMessage {
    public var type: MessageType { .volumeSnapshot }
    public let requestId: String
    public let timestamp: Date
    public let volumeId: String
    public let snapshotId: String
    public let volumePath: String
    public let snapshotPath: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        volumeId: String,
        snapshotId: String,
        volumePath: String,
        snapshotPath: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.volumeId = volumeId
        self.snapshotId = snapshotId
        self.volumePath = volumePath
        self.snapshotPath = snapshotPath
    }
}

/// Message to clone a volume
public struct VolumeCloneMessage: WebSocketMessage {
    public var type: MessageType { .volumeClone }
    public let requestId: String
    public let timestamp: Date
    public let sourceVolumeId: String
    public let sourceVolumePath: String
    public let targetVolumeId: String
    public let targetVolumePath: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sourceVolumeId: String,
        sourceVolumePath: String,
        targetVolumeId: String,
        targetVolumePath: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.sourceVolumeId = sourceVolumeId
        self.sourceVolumePath = sourceVolumePath
        self.targetVolumeId = targetVolumeId
        self.targetVolumePath = targetVolumePath
    }
}

/// Message to get volume information
public struct VolumeInfoMessage: WebSocketMessage {
    public var type: MessageType { .volumeInfo }
    public let requestId: String
    public let timestamp: Date
    public let volumeId: String
    public let volumePath: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        volumeId: String,
        volumePath: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.volumeId = volumeId
        self.volumePath = volumePath
    }
}

/// Response with volume information from agent
public struct VolumeInfoResponse: Codable, Sendable {
    public let volumeId: String
    public let actualSize: Int64     // Actual disk usage
    public let virtualSize: Int64    // Provisioned size
    public let format: String
    public let dirty: Bool           // Has uncommitted changes
    public let encrypted: Bool

    public init(
        volumeId: String,
        actualSize: Int64,
        virtualSize: Int64,
        format: String,
        dirty: Bool = false,
        encrypted: Bool = false
    ) {
        self.volumeId = volumeId
        self.actualSize = actualSize
        self.virtualSize = virtualSize
        self.format = format
        self.dirty = dirty
        self.encrypted = encrypted
    }
}

/// Response for volume operations (create, attach, detach, etc.)
public struct VolumeStatusResponse: Codable, Sendable {
    public let volumeId: String
    public let status: String
    public let storagePath: String?

    public init(
        volumeId: String,
        status: String,
        storagePath: String?
    ) {
        self.volumeId = volumeId
        self.status = status
        self.storagePath = storagePath
    }
}

/// Message to get volume status
public struct VolumeStatusMessage: WebSocketMessage {
    public var type: MessageType { .volumeStatus }
    public let requestId: String
    public let timestamp: Date
    public let volumeId: String

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        volumeId: String
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.volumeId = volumeId
    }
}

// MARK: - Message Envelope

public struct MessageEnvelope: Codable, Sendable {
    public let type: MessageType
    public let payload: Data
    
    public init<T: WebSocketMessage>(message: T) throws {
        self.type = message.type
        self.payload = try JSONEncoder().encode(message)
    }
    
    public func decode<T: WebSocketMessage>(as messageType: T.Type) throws -> T {
        return try JSONDecoder().decode(messageType, from: payload)
    }
}

// MARK: - VM Log Messages

/// Log level for VM log messages
public enum VMLogLevel: String, Codable, Sendable {
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"
}

/// Source of the log message
public enum VMLogSource: String, Codable, Sendable {
    case agent = "agent"
    case qemu = "qemu"
    case controlPlane = "control_plane"
}

/// Type of VM event
public enum VMEventType: String, Codable, Sendable {
    case statusChange = "status_change"
    case operation = "operation"
    case qemuOutput = "qemu_output"
    case error = "error"
    case info = "info"
}

/// VM log message sent from agent to control plane
public struct VMLogMessage: WebSocketMessage {
    public var type: MessageType { .vmLog }
    public let requestId: String
    public let timestamp: Date
    public let vmId: String
    public let level: VMLogLevel
    public let source: VMLogSource
    public let eventType: VMEventType
    public let message: String
    public let operation: String?
    public let details: String?
    public let previousStatus: VMStatus?
    public let newStatus: VMStatus?

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        vmId: String,
        level: VMLogLevel,
        source: VMLogSource,
        eventType: VMEventType,
        message: String,
        operation: String? = nil,
        details: String? = nil,
        previousStatus: VMStatus? = nil,
        newStatus: VMStatus? = nil
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.vmId = vmId
        self.level = level
        self.source = source
        self.eventType = eventType
        self.message = message
        self.operation = operation
        self.details = details
        self.previousStatus = previousStatus
        self.newStatus = newStatus
    }
}