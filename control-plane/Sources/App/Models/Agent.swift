import Fluent
import Vapor
import StratoShared

final class Agent: Model, Content, @unchecked Sendable {
    static let schema = "agents"
    
    @ID(key: .id)
    var id: UUID?
    
    @Field(key: "name")
    var name: String
    
    @Field(key: "hostname")
    var hostname: String
    
    @Field(key: "version")
    var version: String
    
    @Field(key: "capabilities")
    var capabilities: [String]
    
    @Enum(key: "status")
    var status: AgentStatus
    
    @Field(key: "total_cpu")
    var totalCPU: Int
    
    @Field(key: "total_memory")
    var totalMemory: Int64
    
    @Field(key: "total_disk")
    var totalDisk: Int64
    
    @Field(key: "available_cpu")
    var availableCPU: Int
    
    @Field(key: "available_memory")
    var availableMemory: Int64
    
    @Field(key: "available_disk")
    var availableDisk: Int64
    
    @Timestamp(key: "last_heartbeat", on: .none)
    var lastHeartbeat: Date?
    
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?
    
    init() { }
    
    init(
        id: UUID? = nil,
        name: String,
        hostname: String,
        version: String,
        capabilities: [String],
        status: AgentStatus = .offline,
        resources: AgentResources,
        lastHeartbeat: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.version = version
        self.capabilities = capabilities
        self.status = status
        self.totalCPU = resources.totalCPU
        self.totalMemory = resources.totalMemory
        self.totalDisk = resources.totalDisk
        self.availableCPU = resources.availableCPU
        self.availableMemory = resources.availableMemory
        self.availableDisk = resources.availableDisk
        self.lastHeartbeat = lastHeartbeat
    }
    
    func updateResources(_ resources: AgentResources) {
        self.availableCPU = resources.availableCPU
        self.availableMemory = resources.availableMemory
        self.availableDisk = resources.availableDisk
        self.lastHeartbeat = Date()
    }
    
    var resources: AgentResources {
        return AgentResources(
            totalCPU: totalCPU,
            availableCPU: availableCPU,
            totalMemory: totalMemory,
            availableMemory: availableMemory,
            totalDisk: totalDisk,
            availableDisk: availableDisk
        )
    }
}

enum AgentStatus: String, Codable, CaseIterable {
    case online = "online"
    case offline = "offline"
    case connecting = "connecting"
    case error = "error"
}

// MARK: - Agent Extensions for Registration

extension Agent {
    /// Create an agent from registration message
    static func from(registration: AgentRegisterMessage, name: String) -> Agent {
        return Agent(
            name: name,
            hostname: registration.hostname,
            version: registration.version,
            capabilities: registration.capabilities,
            status: .connecting,
            resources: registration.resources,
            lastHeartbeat: Date()
        )
    }
    
    /// Check if agent is considered online based on heartbeat
    var isOnline: Bool {
        guard let lastHeartbeat = lastHeartbeat else { return false }
        return Date().timeIntervalSince(lastHeartbeat) < 60 // 60 seconds timeout
    }
    
    /// Update agent status based on heartbeat age
    func updateStatusBasedOnHeartbeat() {
        if isOnline && status == .offline {
            status = .online
        } else if !isOnline && status == .online {
            status = .offline
        }
    }
}

// MARK: - DTO for API responses

struct AgentResponse: Content {
    let id: UUID
    let name: String
    let hostname: String
    let version: String
    let capabilities: [String]
    let status: AgentStatus
    let resources: AgentResources
    let lastHeartbeat: Date?
    let createdAt: Date?
    let isOnline: Bool
    
    init(from agent: Agent) throws {
        guard let id = agent.id else {
            throw Abort(.internalServerError, reason: "Agent missing ID")
        }
        
        self.id = id
        self.name = agent.name
        self.hostname = agent.hostname
        self.version = agent.version
        self.capabilities = agent.capabilities
        self.status = agent.status
        self.resources = agent.resources
        self.lastHeartbeat = agent.lastHeartbeat
        self.createdAt = agent.createdAt
        self.isOnline = agent.isOnline
    }
}