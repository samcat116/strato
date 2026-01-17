import Foundation

// MARK: - WebSocket Message Types

public enum MessageType: String, Codable, Sendable {
    // Agent registration and heartbeat
    case agentRegister = "agent_register"
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

    // Responses
    case success = "success"
    case error = "error"
    case statusUpdate = "status_update"
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
    
    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        agentId: String,
        hostname: String,
        version: String,
        capabilities: [String],
        resources: AgentResources
    ) {
        self.requestId = requestId
        self.timestamp = timestamp
        self.agentId = agentId
        self.hostname = hostname
        self.version = version
        self.capabilities = capabilities
        self.resources = resources
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