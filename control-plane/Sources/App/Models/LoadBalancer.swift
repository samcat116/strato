import Fluent
import Foundation
import Vapor

enum LoadBalancerProtocol: String, Codable, CaseIterable, Sendable {
    case tcp
    case udp
}

enum LoadBalancerDesiredState: String, Codable, Sendable {
    case active
}

enum LoadBalancerObservedState: String, Codable, Sendable {
    case pending
    case active
    case error
}

enum LoadBalancerBackendHealth: String, Codable, Sendable {
    case unknown
    case online
    case offline
    case error
}

/// A project-scoped L4 virtual IP realized by OVN's native Load_Balancer
/// table (STR-28). The VIP is allocated from the logical network's subnet by
/// `IPAMService`, under the same per-network lock as workload NIC addresses.
final class LoadBalancer: Model, @unchecked Sendable {
    static let schema = "load_balancers"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Parent(key: "project_id")
    var project: Project

    @Parent(key: "logical_network_id")
    var logicalNetwork: LogicalNetwork

    @Field(key: "vip")
    var vip: String

    @Field(key: "protocol")
    var protocolName: LoadBalancerProtocol

    @Field(key: "desired_state")
    var desiredState: LoadBalancerDesiredState

    @Field(key: "observed_state")
    var observedState: LoadBalancerObservedState

    @Field(key: "generation")
    var generation: Int64

    @Field(key: "observed_generation")
    var observedGeneration: Int64

    @OptionalField(key: "last_error")
    var lastError: String?

    @Field(key: "health_check_enabled")
    var healthCheckEnabled: Bool

    @Field(key: "health_check_interval_seconds")
    var healthCheckIntervalSeconds: Int

    @Field(key: "health_check_timeout_seconds")
    var healthCheckTimeoutSeconds: Int

    @Field(key: "health_check_success_threshold")
    var healthCheckSuccessThreshold: Int

    @Field(key: "health_check_failure_threshold")
    var healthCheckFailureThreshold: Int

    @Children(for: \.$loadBalancer)
    var listeners: [LoadBalancerListener]

    @Children(for: \.$loadBalancer)
    var backends: [LoadBalancerBackend]

    @OptionalParent(key: "created_by_id")
    var createdBy: User?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        projectID: UUID,
        logicalNetworkID: UUID,
        vip: String,
        protocolName: LoadBalancerProtocol,
        healthCheck: LoadBalancerHealthCheckConfig = .disabled,
        createdByID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.$project.id = projectID
        self.$logicalNetwork.id = logicalNetworkID
        self.vip = vip
        self.protocolName = protocolName
        self.desiredState = .active
        self.observedState = .pending
        self.generation = 1
        self.observedGeneration = 0
        self.lastError = nil
        self.healthCheckEnabled = healthCheck.enabled
        self.healthCheckIntervalSeconds = healthCheck.intervalSeconds
        self.healthCheckTimeoutSeconds = healthCheck.timeoutSeconds
        self.healthCheckSuccessThreshold = healthCheck.successThreshold
        self.healthCheckFailureThreshold = healthCheck.failureThreshold
        self.$createdBy.id = createdByID
    }

    var healthCheck: LoadBalancerHealthCheckConfig {
        get {
            LoadBalancerHealthCheckConfig(
                enabled: healthCheckEnabled,
                intervalSeconds: healthCheckIntervalSeconds,
                timeoutSeconds: healthCheckTimeoutSeconds,
                successThreshold: healthCheckSuccessThreshold,
                failureThreshold: healthCheckFailureThreshold)
        }
        set {
            healthCheckEnabled = newValue.enabled
            healthCheckIntervalSeconds = newValue.intervalSeconds
            healthCheckTimeoutSeconds = newValue.timeoutSeconds
            healthCheckSuccessThreshold = newValue.successThreshold
            healthCheckFailureThreshold = newValue.failureThreshold
        }
    }
}

extension LoadBalancer: Content {}

final class LoadBalancerListener: Model, @unchecked Sendable {
    static let schema = "load_balancer_listeners"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "load_balancer_id")
    var loadBalancer: LoadBalancer

    @Field(key: "port")
    var port: Int

    @Field(key: "backend_port")
    var backendPort: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, loadBalancerID: UUID, port: Int, backendPort: Int) {
        self.id = id
        self.$loadBalancer.id = loadBalancerID
        self.port = port
        self.backendPort = backendPort
    }
}

extension LoadBalancerListener: Content {}

/// One backend address shared by every listener on a load balancer. A backend
/// is either a VM NIC (`interface_id`) or an off-platform address (`address`).
/// The NIC FK is SET NULL: deleting a VM removes the target from desired state
/// without deleting the load balancer or losing the backend row's audit trail.
final class LoadBalancerBackend: Model, @unchecked Sendable {
    static let schema = "load_balancer_backends"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "load_balancer_id")
    var loadBalancer: LoadBalancer

    @OptionalParent(key: "interface_id")
    var interface: VMNetworkInterface?

    @OptionalField(key: "address")
    var address: String?

    @Field(key: "health_status")
    var healthStatus: LoadBalancerBackendHealth

    @OptionalField(key: "last_health_check_at")
    var lastHealthCheckAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        loadBalancerID: UUID,
        interfaceID: UUID? = nil,
        address: String? = nil
    ) {
        self.id = id
        self.$loadBalancer.id = loadBalancerID
        self.$interface.id = interfaceID
        self.address = address
        self.healthStatus = .unknown
        self.lastHealthCheckAt = nil
    }
}

extension LoadBalancerBackend: Content {}

// MARK: - DTOs

struct LoadBalancerHealthCheckConfig: Content, Equatable, Sendable {
    let enabled: Bool
    let intervalSeconds: Int
    let timeoutSeconds: Int
    let successThreshold: Int
    let failureThreshold: Int

    static let disabled = LoadBalancerHealthCheckConfig(
        enabled: false, intervalSeconds: 5, timeoutSeconds: 2,
        successThreshold: 1, failureThreshold: 3)

    func validate() throws {
        guard (1...300).contains(intervalSeconds) else {
            throw Abort(.badRequest, reason: "Health-check interval must be 1-300 seconds")
        }
        guard (1...60).contains(timeoutSeconds), timeoutSeconds <= intervalSeconds else {
            throw Abort(
                .badRequest, reason: "Health-check timeout must be 1-60 seconds and no longer than the interval")
        }
        guard (1...10).contains(successThreshold), (1...10).contains(failureThreshold) else {
            throw Abort(.badRequest, reason: "Health-check thresholds must be 1-10")
        }
    }
}

struct CreateLoadBalancerRequest: Content, ValidatedRequestBody {
    var name: String
    let projectId: UUID?
    let logicalNetworkId: UUID
    let `protocol`: LoadBalancerProtocol
    let healthCheck: LoadBalancerHealthCheckConfig?

    mutating func validate() throws {
        name = try Validate.name(name)
    }
}

struct UpdateLoadBalancerRequest: Content, ValidatedRequestBody {
    var name: String?
    let `protocol`: LoadBalancerProtocol?
    let healthCheck: LoadBalancerHealthCheckConfig?

    mutating func validate() throws {
        name = try Validate.name(name)
    }
}

struct CreateLoadBalancerListenerRequest: Content {
    let port: Int
    let backendPort: Int
}

typealias UpdateLoadBalancerListenerRequest = CreateLoadBalancerListenerRequest

struct CreateLoadBalancerBackendRequest: Content {
    let vmId: UUID?
    let nicIndex: Int?
    let ipAddress: String?
}

struct LoadBalancerListenerResponse: Content, Sendable {
    let id: UUID
    let port: Int
    let backendPort: Int

    init(from listener: LoadBalancerListener) throws {
        id = try listener.requireID()
        port = listener.port
        backendPort = listener.backendPort
    }
}

struct LoadBalancerBackendResponse: Content, Sendable {
    let id: UUID
    let interfaceId: UUID?
    let vmId: UUID?
    let nicIndex: Int?
    let ipAddress: String?
    let healthStatus: LoadBalancerBackendHealth
    let lastHealthCheckAt: Date?

    init(from backend: LoadBalancerBackend, interface: VMNetworkInterface? = nil) throws {
        id = try backend.requireID()
        interfaceId = backend.$interface.id
        vmId = interface?.$vm.id
        nicIndex = interface?.orderIndex
        ipAddress = interface?.ipv4Address?.address ?? backend.address
        healthStatus = backend.healthStatus
        lastHealthCheckAt = backend.lastHealthCheckAt
    }
}

struct LoadBalancerResponse: Content, Sendable {
    let id: UUID
    let name: String
    let projectId: UUID
    let logicalNetworkId: UUID
    let logicalNetworkName: String?
    let vip: String
    let `protocol`: LoadBalancerProtocol
    let desiredState: LoadBalancerDesiredState
    let observedState: LoadBalancerObservedState
    let generation: Int64
    let observedGeneration: Int64
    let lastError: String?
    let healthCheck: LoadBalancerHealthCheckConfig
    let listeners: [LoadBalancerListenerResponse]
    let backends: [LoadBalancerBackendResponse]
    let createdAt: Date?
    let updatedAt: Date?

    init(
        from loadBalancer: LoadBalancer,
        listeners: [LoadBalancerListener] = [],
        backends: [(LoadBalancerBackend, VMNetworkInterface?)] = []
    ) throws {
        id = try loadBalancer.requireID()
        name = loadBalancer.name
        projectId = loadBalancer.$project.id
        logicalNetworkId = loadBalancer.$logicalNetwork.id
        logicalNetworkName = loadBalancer.$logicalNetwork.value?.name
        vip = loadBalancer.vip
        `protocol` = loadBalancer.protocolName
        desiredState = loadBalancer.desiredState
        observedState = loadBalancer.observedState
        generation = loadBalancer.generation
        observedGeneration = loadBalancer.observedGeneration
        lastError = loadBalancer.lastError
        healthCheck = loadBalancer.healthCheck
        self.listeners = try listeners.map(LoadBalancerListenerResponse.init(from:))
        self.backends = try backends.map { try LoadBalancerBackendResponse(from: $0.0, interface: $0.1) }
        createdAt = loadBalancer.createdAt
        updatedAt = loadBalancer.updatedAt
    }
}
