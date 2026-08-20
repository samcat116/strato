import Fluent
import Foundation
import SQLKit
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

enum LoadBalancer {
    static let schema = "load_balancers"
}

/// Immutable persistence value for a project-scoped L4 virtual IP realized by
/// OVN's native Load_Balancer table. The VIP is allocated from the logical
/// network's subnet under the same per-network lock as workload NIC addresses.
struct LoadBalancerSnapshot: Equatable, Sendable {
    let id: UUID
    let name: String
    let projectID: UUID
    let logicalNetworkID: UUID
    let logicalNetworkName: String?
    let vip: String
    let protocolName: LoadBalancerProtocol
    let desiredState: LoadBalancerDesiredState
    let observedState: LoadBalancerObservedState
    let generation: Int64
    let observedGeneration: Int64
    let lastError: String?
    let healthCheckEnabled: Bool
    let healthCheckIntervalSeconds: Int
    let healthCheckTimeoutSeconds: Int
    let healthCheckSuccessThreshold: Int
    let healthCheckFailureThreshold: Int
    let createdByID: UUID?
    let createdAt: Date?
    let updatedAt: Date?

    var healthCheck: LoadBalancerHealthCheckConfig {
        LoadBalancerHealthCheckConfig(
            enabled: healthCheckEnabled,
            intervalSeconds: healthCheckIntervalSeconds,
            timeoutSeconds: healthCheckTimeoutSeconds,
            successThreshold: healthCheckSuccessThreshold,
            failureThreshold: healthCheckFailureThreshold)
    }
}

enum LegacyLoadBalancerStore {
    static func rows(
        ids: [UUID]? = nil,
        projectIDs: [UUID]? = nil,
        networkIDs: [UUID]? = nil,
        on db: any Database
    ) async throws -> [LoadBalancerSnapshot] {
        if let ids, ids.isEmpty { return [] }
        if let projectIDs, projectIDs.isEmpty { return [] }
        if let networkIDs, networkIDs.isEmpty { return [] }
        var query: SQLQueryString = """
            SELECT \(unsafeRaw: columns)
            FROM load_balancers AS lb
            LEFT JOIN logical_networks AS network ON network.id = lb.logical_network_id
            WHERE TRUE
            """
        if let ids { query += " AND lb.id = ANY(\(bind: ids))" }
        if let projectIDs { query += " AND lb.project_id = ANY(\(bind: projectIDs))" }
        if let networkIDs { query += " AND lb.logical_network_id = ANY(\(bind: networkIDs))" }
        query += " ORDER BY lb.name, lb.id"
        return try await snapshots(from: requireSQL(db).raw(query).all(decoding: Record.self))
    }

    static func find(id: UUID, on db: any Database) async throws -> LoadBalancerSnapshot? {
        try await rows(ids: [id], on: db).first
    }

    static func locked(id: UUID, on db: any Database) async throws -> LoadBalancerSnapshot? {
        guard let row = try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns)
            FROM load_balancers AS lb
            LEFT JOIN logical_networks AS network ON network.id = lb.logical_network_id
            WHERE lb.id = \(bind: id)
            FOR UPDATE OF lb
            """
        ).first(decoding: Record.self) else { return nil }
        return try row.snapshot()
    }

    @discardableResult
    static func insert(
        id: UUID = UUID(),
        name: String,
        projectID: UUID,
        logicalNetworkID: UUID,
        vip: String,
        protocolName: LoadBalancerProtocol,
        healthCheck: LoadBalancerHealthCheckConfig = .disabled,
        createdByID: UUID? = nil,
        on db: any Database
    ) async throws -> LoadBalancerSnapshot {
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO load_balancers (
                id, name, project_id, logical_network_id, vip, protocol,
                desired_state, observed_state, generation, observed_generation,
                last_error, health_check_enabled, health_check_interval_seconds,
                health_check_timeout_seconds, health_check_success_threshold,
                health_check_failure_threshold, created_by_id, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: name), \(bind: projectID), \(bind: logicalNetworkID),
                \(bind: vip), \(bind: protocolName.rawValue),
                \(bind: LoadBalancerDesiredState.active.rawValue),
                \(bind: LoadBalancerObservedState.pending.rawValue), 1, 0, NULL,
                \(bind: healthCheck.enabled), \(bind: healthCheck.intervalSeconds),
                \(bind: healthCheck.timeoutSeconds), \(bind: healthCheck.successThreshold),
                \(bind: healthCheck.failureThreshold), \(bind: createdByID),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not create load balancer")
        }
        return try row.snapshot()
    }

    @discardableResult
    static func updateDefinition(
        id: UUID,
        name: String,
        protocolName: LoadBalancerProtocol,
        healthCheck: LoadBalancerHealthCheckConfig,
        on db: any Database
    ) async throws -> LoadBalancerSnapshot? {
        guard let row = try await requireSQL(db).raw(
            """
            UPDATE load_balancers
            SET name = \(bind: name), protocol = \(bind: protocolName.rawValue),
                health_check_enabled = \(bind: healthCheck.enabled),
                health_check_interval_seconds = \(bind: healthCheck.intervalSeconds),
                health_check_timeout_seconds = \(bind: healthCheck.timeoutSeconds),
                health_check_success_threshold = \(bind: healthCheck.successThreshold),
                health_check_failure_threshold = \(bind: healthCheck.failureThreshold),
                observed_state = \(bind: LoadBalancerObservedState.pending.rawValue),
                last_error = NULL, updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: id)
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else { return nil }
        return try row.snapshot()
    }

    @discardableResult
    static func markPending(id: UUID, on db: any Database) async throws -> UUID? {
        struct Updated: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            """
            UPDATE load_balancers
            SET observed_state = \(bind: LoadBalancerObservedState.pending.rawValue),
                last_error = NULL, updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: id)
            RETURNING id
            """
        ).first(decoding: Updated.self)?.id
    }

    @discardableResult
    static func updateObserved(
        id: UUID,
        observedGeneration: Int64,
        observedState: LoadBalancerObservedState,
        lastError: String?,
        on db: any Database
    ) async throws -> UUID? {
        struct Updated: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            """
            UPDATE load_balancers
            SET observed_generation = \(bind: observedGeneration),
                observed_state = \(bind: observedState.rawValue),
                last_error = \(bind: lastError), updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: id)
            RETURNING id
            """
        ).first(decoding: Updated.self)?.id
    }

    static func usedIPv4Addresses(networkID: UUID, on db: any Database) async throws -> [String] {
        struct Address: Decodable { let vip: String }
        return try await requireSQL(db).raw(
            "SELECT vip FROM load_balancers WHERE logical_network_id = \(bind: networkID)"
        ).all(decoding: Address.self).map(\.vip)
    }

    static func ids(projectIDs: [UUID], on db: any Database) async throws -> [UUID] {
        struct ID: Decodable { let id: UUID }
        guard !projectIDs.isEmpty else { return [] }
        return try await requireSQL(db).raw(
            "SELECT id FROM load_balancers WHERE project_id = ANY(\(bind: projectIDs))"
        ).all(decoding: ID.self).map(\.id)
    }

    @discardableResult
    static func delete(id: UUID, on db: any Database) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM load_balancers WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let name: String
        let projectID: UUID
        let logicalNetworkID: UUID
        let logicalNetworkName: String?
        let vip: String
        let protocolName: String
        let desiredState: String
        let observedState: String
        let generation: Int64
        let observedGeneration: Int64
        let lastError: String?
        let healthCheckEnabled: Bool
        let healthCheckIntervalSeconds: Int
        let healthCheckTimeoutSeconds: Int
        let healthCheckSuccessThreshold: Int
        let healthCheckFailureThreshold: Int
        let createdByID: UUID?
        let createdAt: Date?
        let updatedAt: Date?

        func snapshot() throws -> LoadBalancerSnapshot {
            guard let protocolName = LoadBalancerProtocol(rawValue: protocolName),
                let desiredState = LoadBalancerDesiredState(rawValue: desiredState),
                let observedState = LoadBalancerObservedState(rawValue: observedState)
            else {
                throw Abort(.internalServerError, reason: "Load balancer has invalid persisted state")
            }
            return LoadBalancerSnapshot(
                id: id, name: name, projectID: projectID,
                logicalNetworkID: logicalNetworkID, logicalNetworkName: logicalNetworkName,
                vip: vip, protocolName: protocolName, desiredState: desiredState,
                observedState: observedState, generation: generation,
                observedGeneration: observedGeneration, lastError: lastError,
                healthCheckEnabled: healthCheckEnabled,
                healthCheckIntervalSeconds: healthCheckIntervalSeconds,
                healthCheckTimeoutSeconds: healthCheckTimeoutSeconds,
                healthCheckSuccessThreshold: healthCheckSuccessThreshold,
                healthCheckFailureThreshold: healthCheckFailureThreshold,
                createdByID: createdByID, createdAt: createdAt, updatedAt: updatedAt)
        }
    }

    private static func snapshots(
        from rows: [Record]
    ) async throws -> [LoadBalancerSnapshot] {
        try rows.map { try $0.snapshot() }
    }

    private static let columns = """
        lb.id, lb.name, lb.project_id AS "projectID",
        lb.logical_network_id AS "logicalNetworkID", network.name AS "logicalNetworkName",
        lb.vip, lb.protocol AS "protocolName", lb.desired_state AS "desiredState",
        lb.observed_state AS "observedState", lb.generation,
        lb.observed_generation AS "observedGeneration", lb.last_error AS "lastError",
        lb.health_check_enabled AS "healthCheckEnabled",
        lb.health_check_interval_seconds AS "healthCheckIntervalSeconds",
        lb.health_check_timeout_seconds AS "healthCheckTimeoutSeconds",
        lb.health_check_success_threshold AS "healthCheckSuccessThreshold",
        lb.health_check_failure_threshold AS "healthCheckFailureThreshold",
        lb.created_by_id AS "createdByID", lb.created_at AS "createdAt",
        lb.updated_at AS "updatedAt"
        """

    private static let returningColumns = """
        id, name, project_id AS "projectID", logical_network_id AS "logicalNetworkID",
        NULL::text AS "logicalNetworkName", vip, protocol AS "protocolName",
        desired_state AS "desiredState", observed_state AS "observedState", generation,
        observed_generation AS "observedGeneration", last_error AS "lastError",
        health_check_enabled AS "healthCheckEnabled",
        health_check_interval_seconds AS "healthCheckIntervalSeconds",
        health_check_timeout_seconds AS "healthCheckTimeoutSeconds",
        health_check_success_threshold AS "healthCheckSuccessThreshold",
        health_check_failure_threshold AS "healthCheckFailureThreshold",
        created_by_id AS "createdByID", created_at AS "createdAt", updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Load balancers require PostgreSQL")
        }
        return sql
    }
}

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

    init(from listener: LoadBalancerListenerSnapshot) {
        id = listener.id
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

    init(from backend: LoadBalancerBackendSnapshot, interface: VMNetworkInterface? = nil) {
        id = backend.id
        interfaceId = backend.interfaceID
        vmId = interface?.vmID
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
        from loadBalancer: LoadBalancerSnapshot,
        listeners: [LoadBalancerListenerSnapshot] = [],
        backends: [(LoadBalancerBackendSnapshot, VMNetworkInterface?)] = []
    ) {
        id = loadBalancer.id
        name = loadBalancer.name
        projectId = loadBalancer.projectID
        logicalNetworkId = loadBalancer.logicalNetworkID
        logicalNetworkName = loadBalancer.logicalNetworkName
        vip = loadBalancer.vip
        `protocol` = loadBalancer.protocolName
        desiredState = loadBalancer.desiredState
        observedState = loadBalancer.observedState
        generation = loadBalancer.generation
        observedGeneration = loadBalancer.observedGeneration
        lastError = loadBalancer.lastError
        healthCheck = loadBalancer.healthCheck
        self.listeners = listeners.map(LoadBalancerListenerResponse.init(from:))
        self.backends = backends.map { LoadBalancerBackendResponse(from: $0.0, interface: $0.1) }
        createdAt = loadBalancer.createdAt
        updatedAt = loadBalancer.updatedAt
    }
}
