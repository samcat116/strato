import Foundation

// Hand-written mirrors of the control plane's REST DTOs (reference:
// control-plane/web/src/types/api.ts). The backend's own structs are internal
// and Fluent-coupled, and the OpenAPI spec is still a stub (#557), so the CLI
// decodes just the fields it shows — everything non-essential is optional so
// server additions never break an older CLI.

public struct VM: Codable, Sendable {
    public let id: UUID?
    public let name: String
    public let description: String?
    public let image: String?
    public let imageId: UUID?
    public let projectId: UUID?
    public let status: String
    public let cpu: Int?
    public let memory: Int64?
    public let memoryFormatted: String?
    public let disk: Int64?
    public let diskFormatted: String?
    public let createdAt: Date?
}

public struct Sandbox: Codable, Sendable {
    public let id: UUID?
    public let name: String
    public let projectId: UUID?
    public let environment: String?
    public let image: String
    public let cpus: Int?
    public let memory: Int64?
    public let status: String
    public let exitCode: Int?
    public let expiresAt: Date?
    public let createdAt: Date?
}

public struct Volume: Codable, Sendable {
    public let id: UUID?
    public let name: String
    public let description: String?
    public let projectId: UUID?
    public let size: Int64?
    public let sizeFormatted: String?
    public let format: String?
    public let volumeType: String?
    public let status: String?
    public let vmId: UUID?
    public let createdAt: Date?
}

public struct Image: Codable, Sendable {
    public let id: UUID?
    public let name: String
    public let description: String?
    public let projectId: UUID?
    public let size: Int64?
    public let sizeFormatted: String?
    public let format: String?
    public let architecture: String?
    public let status: String?
    public let createdAt: Date?
}

public struct Network: Codable, Sendable {
    public let id: UUID?
    public let name: String
    public let subnet: String
    public let gateway: String?
    public let subnet6: String?
    public let projectId: UUID?
    public let isDefault: Bool?
    public let attachedInterfaceCount: Int?
    public let dhcpEnabled: Bool?
    public let createdAt: Date?
}

public struct Agent: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let hostname: String?
    public let version: String?
    public let status: String?
    public let architecture: String?
    public let operatingSystem: String?
    public let isOnline: Bool?
    public let lastHeartbeat: Date?
    public let createdAt: Date?
}

public struct AgentEnrollment: Codable, Sendable {
    public let id: UUID?
    public let agentName: String
    public let spiffeId: String?
    public let expiresAt: Date?
    public let bootstrapCommand: String
}

public struct Project: Codable, Sendable {
    public let id: UUID?
    public let name: String
    public let description: String?
    public let organizationId: UUID?
    public let organizationalUnitId: UUID?
    public let path: String?
    public let defaultEnvironment: String?
    public let environments: [String]?
    public let createdAt: Date?
    public let vmCount: Int?
}

public struct Organization: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String?
    public let createdAt: Date?
    public let userRole: String?
}

public struct QuotaLimits: Codable, Sendable {
    public let maxVCPUs: Int?
    public let maxMemoryGB: Double?
    public let maxStorageGB: Double?
    public let maxVMs: Int?
}

public struct ResourceQuota: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let entityType: String?
    public let entityId: UUID?
    public let environment: String?
    public let isEnabled: Bool?
    public let limits: QuotaLimits?
    public let createdAt: Date?
}

// MARK: - Requests

public struct CreateVMRequest: Codable, Sendable {
    public let name: String
    public let description: String?
    public let imageId: String
    public let projectId: String?
    public let environment: String?
    public let cpu: Int?
    public let memory: Int64?
    public let disk: Int64?
    public let networkId: String?
    public let sshPublicKey: String?
    public let userData: String?

    public init(
        name: String, description: String?, imageId: String, projectId: String?,
        environment: String?, cpu: Int?, memory: Int64?, disk: Int64?, networkId: String?,
        sshPublicKey: String?, userData: String?
    ) {
        self.name = name
        self.description = description
        self.imageId = imageId
        self.projectId = projectId
        self.environment = environment
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.networkId = networkId
        self.sshPublicKey = sshPublicKey
        self.userData = userData
    }
}

public struct CreateSandboxRequest: Codable, Sendable {
    public let name: String
    public let image: String?
    public let projectId: String?
    public let environment: String?
    public let cpus: Int?
    public let memory: Int64?
    public let ttlSeconds: Int?

    public init(
        name: String, image: String?, projectId: String?, environment: String?,
        cpus: Int?, memory: Int64?, ttlSeconds: Int?
    ) {
        self.name = name
        self.image = image
        self.projectId = projectId
        self.environment = environment
        self.cpus = cpus
        self.memory = memory
        self.ttlSeconds = ttlSeconds
    }
}

public struct CreateVolumeRequest: Codable, Sendable {
    public let name: String
    public let description: String?
    public let projectId: String?
    public let sizeGB: Int
    public let format: String?
    public let volumeType: String?

    public init(
        name: String, description: String?, projectId: String?, sizeGB: Int,
        format: String?, volumeType: String?
    ) {
        self.name = name
        self.description = description
        self.projectId = projectId
        self.sizeGB = sizeGB
        self.format = format
        self.volumeType = volumeType
    }
}

public struct CreateNetworkRequest: Codable, Sendable {
    public let name: String
    public let subnet: String
    public let gateway: String?
    public let projectId: String?
    public let dhcpEnabled: Bool?

    public init(name: String, subnet: String, gateway: String?, projectId: String?, dhcpEnabled: Bool?) {
        self.name = name
        self.subnet = subnet
        self.gateway = gateway
        self.projectId = projectId
        self.dhcpEnabled = dhcpEnabled
    }
}

public struct CreateProjectRequest: Codable, Sendable {
    public let name: String
    public let description: String?
    public let defaultEnvironment: String?

    public init(name: String, description: String?, defaultEnvironment: String?) {
        self.name = name
        self.description = description
        self.defaultEnvironment = defaultEnvironment
    }
}

public struct CreateAgentEnrollmentRequest: Codable, Sendable {
    public let agentName: String
    public let expirationHours: Int?
    public let siteId: String?
    public let organizationId: String?
    public let organizationalUnitId: String?

    public init(
        agentName: String, expirationHours: Int?, siteId: String?,
        organizationId: String?, organizationalUnitId: String?
    ) {
        self.agentName = agentName
        self.expirationHours = expirationHours
        self.siteId = siteId
        self.organizationId = organizationId
        self.organizationalUnitId = organizationalUnitId
    }
}
