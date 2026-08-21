import Foundation
import PostgresNIO
import StratoShared

/// Immutable persistence representation of one registered control-plane agent.
///
/// The transport layer deliberately remains responsible for translating the
/// string-backed database enums and for computing presentation-only liveness.
public struct AgentSnapshot: Sendable {
    public let id: UUID
    public let name: String
    public let trustDomain: String
    public let hostname: String
    public let version: String
    public let status: String
    public let resources: AgentResources
    public let architecture: String?
    public let operatingSystem: String?
    public let hypervisors: [HypervisorSupport]
    public let networkCapability: String?
    public let hostInfo: HostInfo?
    public let siteID: UUID
    public let sandboxCapable: Bool
    public let sandboxNetworkingCapable: Bool
    public let tpmCapable: Bool
    public let resolverCapable: Bool
    public let metadataServiceCapable: Bool
    public let dependencyObservations: [NodeDependencyObservation]
    public let dependencyObservationsReceivedAt: Date?
    public let organizationID: UUID?
    public let organizationalUnitID: UUID?
    public let autoUpdate: Bool
    public let updateDesiredVersion: String?
    public let updateAssignmentSource: String?
    public let updateAttemptedAt: Date?
    public let updateBlockedReason: String?
    public let updateFailureReason: String?
    public let teardownRefusalReason: String?
    public let teardownRefusedAt: Date?
    public let manifestStatusReason: String?
    public let manifestStatusAt: Date?
    public let manifestInventoryComplete: Bool?
    public let lastHeartbeat: Date?
    public let createdAt: Date?
    public let updatedAt: Date?

    public var isOnline: Bool {
        guard let lastHeartbeat else { return false }
        return Date().timeIntervalSince(lastHeartbeat) < 60
    }

    public var statusBasedOnHeartbeat: String {
        if isOnline && status == "offline" { return "online" }
        if !isOnline && status == "online" { return "offline" }
        return status
    }

    public func dependencyAllows(
        _ capability: NodeCapability,
        at now: Date = Date(),
        staleAfter: TimeInterval = 60
    ) -> Bool {
        let relevant = dependencyObservations.filter {
            $0.affectedCapabilities.contains(capability)
        }
        guard !relevant.isEmpty, let receivedAt = dependencyObservationsReceivedAt else {
            return false
        }
        return relevant.allSatisfy {
            $0.allowsNewWork(receivedAt: receivedAt, at: now, staleAfter: staleAfter)
        }
    }

    public var supportsInterVMNetworking: Bool {
        networkCapability == NetworkCapability.overlay.rawValue
            && dependencyAllows(.overlayNetworking)
    }

    public var effectiveSandboxNetworkingCapable: Bool {
        sandboxNetworkingCapable && dependencyAllows(.sandboxNetworking)
    }

    public var effectiveResolverCapable: Bool {
        resolverCapable && dependencyAllows(.networkResolver)
    }
}

public enum AgentsPersistenceError: Error, Equatable, Sendable {
    case unexpectedRowCount(expected: Int, actual: Int)
}

public struct AgentUpdateCancellationResult: Sendable {
    public let agent: AgentSnapshot
    public let cancelledVersion: String?
}

public enum AgentDeregistrationResult: Equatable, Sendable {
    case deleted
    case notFound
    case controlsPopulatedSite(UUID)
}

public struct AgentsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func agent(id: UUID) async throws -> AgentSnapshot? {
        try await database.withSession(operation: "agents.lookup") { session in
            let rows = try await session.execute(
                FindAgent(id: id),
                operation: "agents.lookup.query"
            )
            guard rows.count <= 1 else {
                throw AgentsPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
            }
            return rows.first?.snapshot
        }
    }

    public func agent(trustDomain: String, name: String) async throws -> AgentSnapshot? {
        try await database.withSession(operation: "agents.lookup_identity") { session in
            let rows = try await session.execute(
                FindAgentByIdentity(trustDomain: trustDomain, name: name),
                operation: "agents.lookup_identity.query"
            )
            guard rows.count <= 1 else {
                throw AgentsPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
            }
            return rows.first?.snapshot
        }
    }

    public func allAgents() async throws -> [AgentSnapshot] {
        try await database.withSession(operation: "agents.list") { session in
            try await session.execute(
                ListAgents(),
                operation: "agents.list.query"
            ).map(\.snapshot)
        }
    }

    public func agents(organizationID: UUID, organizationalUnitIDs: [UUID]) async throws
        -> [AgentSnapshot]
    {
        try await database.withSession(operation: "agents.list_scoped") { session in
            try await session.execute(
                ListScopedAgents(
                    organizationID: organizationID,
                    organizationalUnitIDs: organizationalUnitIDs
                ),
                operation: "agents.list_scoped.query"
            ).map(\.snapshot)
        }
    }

    public func forceOffline(id: UUID) async throws -> AgentSnapshot? {
        try await database.withSession(operation: "agents.force_offline") { session in
            try oneOrNone(
                await session.execute(
                    SetAgentOffline(id: id),
                    operation: "agents.force_offline.query"
                )
            )?.snapshot
        }
    }

    public func cancelUpdate(id: UUID) async throws -> AgentUpdateCancellationResult? {
        try await database.withTransaction(operation: "agents.cancel_update") { session in
            guard
                let current = try oneOrNone(
                    await session.execute(
                        LockAgent(id: id),
                        operation: "agents.cancel_update.lock"
                    )
                )?.snapshot
            else { return nil }
            guard current.updateDesiredVersion != nil else {
                return AgentUpdateCancellationResult(agent: current, cancelledVersion: nil)
            }
            let updated = try only(
                await session.execute(
                    ClearAgentUpdate(id: id),
                    operation: "agents.cancel_update.query"
                )
            ).snapshot
            return AgentUpdateCancellationResult(
                agent: updated,
                cancelledVersion: current.updateDesiredVersion
            )
        }
    }

    public func setAutoUpdate(id: UUID, enabled: Bool) async throws -> AgentSnapshot? {
        try await database.withTransaction(operation: "agents.set_auto_update") { session in
            guard
                let current = try oneOrNone(
                    await session.execute(
                        LockAgent(id: id),
                        operation: "agents.set_auto_update.lock"
                    )
                )?.snapshot
            else { return nil }
            guard current.autoUpdate != enabled else { return current }

            let statement: SetAgentAutoUpdate
            if enabled {
                statement = SetAgentAutoUpdate(id: id, mode: .enable)
            } else if current.updateDesiredVersion != nil
                && (current.updateAssignmentSource ?? "rollout") == "manual"
            {
                statement = SetAgentAutoUpdate(id: id, mode: .disablePreservingManual)
            } else {
                statement = SetAgentAutoUpdate(id: id, mode: .disableAndClearRollout)
            }
            return try only(
                await session.execute(
                    statement,
                    operation: "agents.set_auto_update.query"
                )
            ).snapshot
        }
    }

    public func hostedSandboxCount(id: UUID) async throws -> Int {
        try await database.withSession(operation: "agents.hosted_sandboxes.count") { session in
            let rows = try await session.execute(
                CountAgentSandboxes(id: id),
                operation: "agents.hosted_sandboxes.count.query"
            )
            guard rows.count == 1, let count = rows.first else {
                throw AgentsPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
            }
            return count
        }
    }

    public func assignManualUpdate(
        id: UUID,
        version: String,
        artifactOverrideJSON: String?
    ) async throws -> AgentSnapshot? {
        try await database.withSession(operation: "agents.assign_manual_update") { session in
            try oneOrNone(
                await session.execute(
                    AssignAgentManualUpdate(
                        id: id,
                        version: version,
                        artifactOverrideJSON: artifactOverrideJSON
                    ),
                    operation: "agents.assign_manual_update.query"
                )
            )?.snapshot
        }
    }

    public func deregistrationBlocker(id: UUID) async throws -> UUID? {
        try await database.withSession(operation: "agents.deregister.preflight") { session in
            try oneOrNone(await session.execute(
                FindControlledPopulatedSite(agentID: id),
                operation: "agents.deregister.preflight.query"))
        }
    }

    /// Clears only last-member site controller designations and removes the
    /// agent plus its registry identity in one transaction. The populated-site
    /// check is repeated here after the external SPIRE revocation preflight so
    /// a concurrent site membership cannot leave a dangling controller id.
    public func deregister(id: UUID, spiffeID: String) async throws -> AgentDeregistrationResult {
        try await database.withTransaction(operation: "agents.deregister") { session in
            guard try oneOrNone(await session.execute(
                LockAgent(id: id), operation: "agents.deregister.lock")) != nil
            else { return .notFound }

            if let siteID = try oneOrNone(await session.execute(
                FindControlledPopulatedSite(agentID: id),
                operation: "agents.deregister.check_site"))
            {
                return .controlsPopulatedSite(siteID)
            }
            _ = try await session.execute(
                ClearLastMemberSiteController(agentID: id),
                operation: "agents.deregister.clear_site_controller")
            _ = try await session.execute(
                DeleteAgentWorkloadRegistration(spiffeID: spiffeID),
                operation: "agents.deregister.registry")
            let deleted = try await session.execute(
                DeleteAgent(id: id),
                operation: "agents.deregister.delete")
            return deleted.count == 1 ? .deleted : .notFound
        }
    }

    private func oneOrNone<T>(_ rows: [T]) throws -> T? {
        guard rows.count <= 1 else {
            throw AgentsPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first
    }

    private func only<T>(_ rows: [T]) throws -> T {
        guard rows.count == 1, let value = rows.first else {
            throw AgentsPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return value
    }
}

struct AgentRecord: Sendable {
    let snapshot: AgentSnapshot

    init(row: PostgresRow) throws {
        let row = row.makeRandomAccess()
        snapshot = AgentSnapshot(
            id: try row["id"].decode(UUID.self),
            name: try row["name"].decode(String.self),
            trustDomain: try row["trust_domain"].decode(String.self),
            hostname: try row["hostname"].decode(String.self),
            version: try row["version"].decode(String.self),
            status: try row["status"].decode(String.self),
            resources: AgentResources(
                totalCPU: try row["total_cpu"].decode(Int.self),
                availableCPU: try row["available_cpu"].decode(Int.self),
                totalMemory: try row["total_memory"].decode(Int64.self),
                availableMemory: try row["available_memory"].decode(Int64.self),
                totalDisk: try row["total_disk"].decode(Int64.self),
                availableDisk: try row["available_disk"].decode(Int64.self)
            ),
            architecture: try row["architecture"].decode(String?.self),
            operatingSystem: try row["operating_system"].decode(String?.self),
            hypervisors: try row["hypervisors"].decode(HypervisorSupportArrayJSON.self).value,
            networkCapability: try row["network_capability"].decode(String?.self),
            hostInfo: try row["host_info"].decode(HostInfoJSON?.self)?.value,
            siteID: try row["site_id"].decode(UUID.self),
            sandboxCapable: try row["sandbox_capable"].decode(Bool.self),
            sandboxNetworkingCapable: try row["sandbox_networking_capable"].decode(Bool.self),
            tpmCapable: try row["tpm_capable"].decode(Bool.self),
            resolverCapable: try row["resolver_capable"].decode(Bool.self),
            metadataServiceCapable: try row["metadata_service_capable"].decode(Bool.self),
            dependencyObservations: try row["dependency_observations"]
                .decode(NodeDependencyObservationArrayJSON.self).value,
            dependencyObservationsReceivedAt: try row["dependency_observations_received_at"]
                .decode(Date?.self),
            organizationID: try row["organization_id"].decode(UUID?.self),
            organizationalUnitID: try row["organizational_unit_id"].decode(UUID?.self),
            autoUpdate: try row["auto_update"].decode(Bool.self),
            updateDesiredVersion: try row["update_desired_version"].decode(String?.self),
            updateAssignmentSource: try row["update_assignment_source"].decode(String?.self),
            updateAttemptedAt: try row["update_attempted_at"].decode(Date?.self),
            updateBlockedReason: try row["update_blocked_reason"].decode(String?.self),
            updateFailureReason: try row["update_failure_reason"].decode(String?.self),
            teardownRefusalReason: try row["teardown_refusal_reason"].decode(String?.self),
            teardownRefusedAt: try row["teardown_refused_at"].decode(Date?.self),
            manifestStatusReason: try row["manifest_status_reason"].decode(String?.self),
            manifestStatusAt: try row["manifest_status_at"].decode(Date?.self),
            manifestInventoryComplete: try row["manifest_inventory_complete"].decode(Bool?.self),
            lastHeartbeat: try row["last_heartbeat"].decode(Date?.self),
            createdAt: try row["created_at"].decode(Date?.self),
            updatedAt: try row["updated_at"].decode(Date?.self)
        )
    }
}

let agentColumns = """
    a.id, a.name, a.trust_domain, a.hostname, a.version, a.status::text AS status,
    a.total_cpu, a.total_memory, a.total_disk,
    a.available_cpu, a.available_memory, a.available_disk,
    a.architecture, a.operating_system, a.hypervisors,
    a.network_capability, a.host_info, a.site_id,
    a.sandbox_capable, a.sandbox_networking_capable, a.tpm_capable,
    a.resolver_capable, a.metadata_service_capable,
    a.dependency_observations, a.dependency_observations_received_at,
    a.organization_id, a.organizational_unit_id, a.auto_update,
    a.update_desired_version, a.update_assignment_source, a.update_attempted_at,
    a.update_blocked_reason, a.update_failure_reason,
    a.teardown_refusal_reason, a.teardown_refused_at,
    a.manifest_status_reason, a.manifest_status_at, a.manifest_inventory_complete,
    a.last_heartbeat, a.created_at, a.updated_at
    """

protocol AgentStatement: PostgresPreparedStatement where Row == AgentRecord {}

extension AgentStatement {
    func decodeRow(_ row: PostgresRow) throws -> AgentRecord { try AgentRecord(row: row) }
}

private struct FindAgent: AgentStatement {
    static var sql: String { "SELECT \(agentColumns) FROM agents AS a WHERE a.id = $1" }
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct FindAgentByIdentity: AgentStatement {
    static var sql: String {
        """
        SELECT \(agentColumns) FROM agents AS a
        WHERE a.trust_domain = $1 AND a.name = $2
        """
    }
    let trustDomain: String
    let name: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(trustDomain)
        bindings.append(name)
        return bindings
    }
}

private struct FindControlledPopulatedSite: PostgresPreparedStatement {
    static let sql = """
        SELECT s.id
        FROM sites AS s
        WHERE s.network_controller_agent_id = $1
          AND EXISTS (
              SELECT 1 FROM agents AS other
              WHERE other.site_id = s.id AND other.id <> $1
          )
        ORDER BY s.id
        LIMIT 1
        """
    typealias Row = UUID
    let agentID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(agentID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.makeRandomAccess()["id"].decode(UUID.self)
    }
}

private struct ClearLastMemberSiteController: PostgresPreparedStatement {
    static let sql = """
        UPDATE sites AS s
        SET network_controller_agent_id = NULL, updated_at = CURRENT_TIMESTAMP
        WHERE s.network_controller_agent_id = $1
          AND NOT EXISTS (
              SELECT 1 FROM agents AS other
              WHERE other.site_id = s.id AND other.id <> $1
          )
        RETURNING s.id
        """
    typealias Row = UUID
    let agentID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(agentID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.makeRandomAccess()["id"].decode(UUID.self)
    }
}

private struct DeleteAgentWorkloadRegistration: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM workload_registrations
        WHERE kind = 'agent' AND spiffe_id = $1
        RETURNING id
        """
    typealias Row = UUID
    let spiffeID: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(spiffeID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.makeRandomAccess()["id"].decode(UUID.self)
    }
}

private struct DeleteAgent: PostgresPreparedStatement {
    static let sql = "DELETE FROM agents WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.makeRandomAccess()["id"].decode(UUID.self)
    }
}

private struct ListAgents: AgentStatement {
    static var sql: String {
        "SELECT \(agentColumns) FROM agents AS a ORDER BY a.created_at DESC, a.id DESC"
    }
    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct ListScopedAgents: AgentStatement {
    static var sql: String {
        """
        SELECT \(agentColumns) FROM agents AS a
        WHERE a.organization_id = $1
           OR a.organizational_unit_id = ANY($2::uuid[])
        ORDER BY a.created_at DESC, a.id DESC
        """
    }
    let organizationID: UUID
    let organizationalUnitIDs: [UUID]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(organizationID)
        bindings.append(organizationalUnitIDs)
        return bindings
    }
}

private struct LockAgent: AgentStatement {
    static var sql: String {
        "SELECT \(agentColumns) FROM agents AS a WHERE a.id = $1 FOR UPDATE OF a"
    }
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct SetAgentOffline: AgentStatement {
    static var sql: String {
        """
        WITH updated AS (
            UPDATE agents SET status = 'offline', updated_at = CURRENT_TIMESTAMP
            WHERE id = $1 RETURNING *
        )
        SELECT \(agentColumns) FROM updated AS a
        """
    }
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct ClearAgentUpdate: AgentStatement {
    static var sql: String {
        """
        WITH updated AS (
            UPDATE agents SET
                update_desired_version = NULL,
                update_assignment_source = NULL,
                update_artifact_override = NULL,
                update_attempted_at = NULL,
                update_blocked_reason = NULL,
                update_failure_reason = NULL,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = $1 RETURNING *
        )
        SELECT \(agentColumns) FROM updated AS a
        """
    }
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct SetAgentAutoUpdate: AgentStatement {
    enum Mode: Equatable, Sendable {
        case enable
        case disablePreservingManual
        case disableAndClearRollout
    }

    static var sql: String {
        """
        WITH updated AS (
            UPDATE agents SET
                auto_update = $2,
                update_desired_version = CASE WHEN $3 THEN NULL ELSE update_desired_version END,
                update_assignment_source = CASE WHEN $3 THEN NULL ELSE update_assignment_source END,
                update_artifact_override = CASE WHEN $3 THEN NULL ELSE update_artifact_override END,
                update_attempted_at = CASE
                    WHEN $3 THEN NULL
                    WHEN $2 AND update_desired_version IS NOT NULL THEN CURRENT_TIMESTAMP
                    ELSE update_attempted_at
                END,
                update_blocked_reason = CASE WHEN $3 THEN NULL ELSE update_blocked_reason END,
                update_failure_reason = CASE
                    WHEN $3 OR $2 THEN NULL
                    ELSE update_failure_reason
                END,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = $1 RETURNING *
        )
        SELECT \(agentColumns) FROM updated AS a
        """
    }
    let id: UUID
    let mode: Mode
    func makeBindings() -> PostgresBindings {
        let enabled = mode == .enable
        let clearAssignment = mode == .disableAndClearRollout
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(enabled)
        bindings.append(clearAssignment)
        return bindings
    }
}

private struct CountAgentSandboxes: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM sandboxes WHERE hypervisor_id = $1"
    static let bindingDataTypes: [PostgresDataType] = [.text]
    typealias Row = Int
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id.uuidString)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct AssignAgentManualUpdate: AgentStatement {
    static var sql: String {
        """
        WITH updated AS (
            UPDATE agents SET
                update_desired_version = $2,
                update_assignment_source = 'manual',
                update_artifact_override = $3::jsonb,
                update_attempted_at = CURRENT_TIMESTAMP,
                update_blocked_reason = NULL,
                update_failure_reason = NULL,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = $1 RETURNING *
        )
        SELECT \(agentColumns) FROM updated AS a
        """
    }
    static let bindingDataTypes: [PostgresDataType] = [.uuid, .text, .text]
    let id: UUID
    let version: String
    let artifactOverrideJSON: String?
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(version)
        bindings.append(artifactOverrideJSON)
        return bindings
    }
}

private struct HypervisorSupportArrayJSON: Decodable, PostgresDecodable, Sendable {
    let value: [HypervisorSupport]

    init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode([HypervisorSupport].self)
    }
}

private struct HostInfoJSON: Decodable, PostgresDecodable, Sendable {
    let value: HostInfo

    init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode(HostInfo.self)
    }
}

private struct NodeDependencyObservationArrayJSON: Decodable, PostgresDecodable, Sendable {
    let value: [NodeDependencyObservation]

    init(from decoder: any Decoder) throws {
        value = try decoder.singleValueContainer().decode([NodeDependencyObservation].self)
    }
}
