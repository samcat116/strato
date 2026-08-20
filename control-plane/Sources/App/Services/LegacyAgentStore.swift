import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

/// Explicit agent access for callers that still own a Fluent transaction.
/// JSON columns are encoded at the boundary and only immutable values escape.
enum LegacyAgentStore {
    static func agent(id: UUID?, on db: any Database) async throws -> Agent? {
        guard let id else { return nil }
        return try await agents(ids: [id], on: db).first
    }

    static func agents(
        ids: [UUID]? = nil,
        trustDomain: String? = nil,
        name: String? = nil,
        siteID: UUID? = nil,
        status: AgentStatus? = nil,
        organizationID: UUID? = nil,
        organizationalUnitID: UUID? = nil,
        excludingID: UUID? = nil,
        autoUpdateOrAssigned: Bool = false,
        orderByName: Bool = false,
        on db: any Database
    ) async throws -> [Agent] {
        if ids?.isEmpty == true { return [] }
        var query: SQLQueryString = "SELECT \(unsafeRaw: columns) FROM agents AS a WHERE TRUE"
        if let ids { query += " AND a.id = ANY(\(bind: ids))" }
        if let trustDomain { query += " AND a.trust_domain = \(bind: trustDomain)" }
        if let name { query += " AND a.name = \(bind: name)" }
        if let siteID { query += " AND a.site_id = \(bind: siteID)" }
        if let status { query += " AND a.status = \(bind: status.rawValue)" }
        if let organizationID { query += " AND a.organization_id = \(bind: organizationID)" }
        if let organizationalUnitID {
            query += " AND a.organizational_unit_id = \(bind: organizationalUnitID)"
        }
        if let excludingID { query += " AND a.id <> \(bind: excludingID)" }
        if autoUpdateOrAssigned {
            query += " AND (a.auto_update = TRUE OR a.update_desired_version IS NOT NULL)"
        }
        query += orderByName
            ? " ORDER BY a.name, a.id"
            : " ORDER BY a.created_at DESC, a.id DESC"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map { try $0.agent }
    }

    static func count(
        siteID: UUID? = nil,
        excludingID: UUID? = nil,
        on db: any Database
    ) async throws -> Int {
        struct Count: Decodable { let count: Int }
        var query: SQLQueryString = "SELECT count(*)::bigint AS count FROM agents WHERE TRUE"
        if let siteID { query += " AND site_id = \(bind: siteID)" }
        if let excludingID { query += " AND id <> \(bind: excludingID)" }
        return try await requireSQL(db).raw(query).first(decoding: Count.self)?.count ?? 0
    }

    @discardableResult
    static func upsert(_ agent: Agent, on db: any Database) async throws -> Agent {
        let id = try agent.requireID()
        let hypervisors = try json(agent.hypervisors)
        let hostInfo = try jsonIfPresent(agent.hostInfo)
        let dependencyObservations = try json(agent.dependencyObservations)
        let updateArtifactOverride = try jsonIfPresent(agent.updateArtifactOverride)
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO agents (
                id, name, trust_domain, hostname, version, status,
                total_cpu, total_memory, total_disk,
                available_cpu, available_memory, available_disk,
                last_heartbeat, architecture, operating_system, hypervisors,
                network_capability, host_info, site_id, wire_protocol_version,
                sandbox_capable, sandbox_networking_capable, tpm_capable,
                resolver_capable, metadata_service_capable,
                dependency_observations, dependency_observations_received_at,
                organization_id, organizational_unit_id, auto_update,
                update_desired_version, update_assignment_source,
                update_artifact_override, update_attempted_at,
                update_blocked_reason, update_failure_reason,
                teardown_refusal_reason, teardown_refused_at,
                manifest_status_reason, manifest_status_at,
                manifest_inventory_complete, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: agent.name), \(bind: agent.trustDomain),
                \(bind: agent.hostname), \(bind: agent.version), \(bind: agent.status.rawValue),
                \(bind: agent.totalCPU), \(bind: agent.totalMemory), \(bind: agent.totalDisk),
                \(bind: agent.availableCPU), \(bind: agent.availableMemory),
                \(bind: agent.availableDisk), \(bind: agent.lastHeartbeat),
                \(bind: agent.architecture), \(bind: agent.operatingSystem),
                CAST(\(bind: hypervisors) AS jsonb), \(bind: agent.networkCapability),
                CAST(\(bind: hostInfo) AS jsonb), \(bind: agent.siteID),
                \(bind: agent.wireProtocolVersion), \(bind: agent.sandboxCapable),
                \(bind: agent.sandboxNetworkingCapable), \(bind: agent.tpmCapable),
                \(bind: agent.resolverCapable), \(bind: agent.metadataServiceCapable),
                CAST(\(bind: dependencyObservations) AS jsonb),
                \(bind: agent.dependencyObservationsReceivedAt),
                \(bind: agent.organizationID), \(bind: agent.organizationalUnitID),
                \(bind: agent.autoUpdate), \(bind: agent.updateDesiredVersion),
                \(bind: agent.updateAssignmentSourceRaw),
                CAST(\(bind: updateArtifactOverride) AS jsonb),
                \(bind: agent.updateAttemptedAt), \(bind: agent.updateBlockedReason),
                \(bind: agent.updateFailureReason), \(bind: agent.teardownRefusalReason),
                \(bind: agent.teardownRefusedAt), \(bind: agent.manifestStatusReason),
                \(bind: agent.manifestStatusAt), \(bind: agent.manifestInventoryComplete),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name,
                trust_domain = EXCLUDED.trust_domain,
                hostname = EXCLUDED.hostname,
                version = EXCLUDED.version,
                status = EXCLUDED.status,
                total_cpu = EXCLUDED.total_cpu,
                total_memory = EXCLUDED.total_memory,
                total_disk = EXCLUDED.total_disk,
                available_cpu = EXCLUDED.available_cpu,
                available_memory = EXCLUDED.available_memory,
                available_disk = EXCLUDED.available_disk,
                last_heartbeat = EXCLUDED.last_heartbeat,
                architecture = EXCLUDED.architecture,
                operating_system = EXCLUDED.operating_system,
                hypervisors = EXCLUDED.hypervisors,
                network_capability = EXCLUDED.network_capability,
                host_info = EXCLUDED.host_info,
                site_id = EXCLUDED.site_id,
                wire_protocol_version = EXCLUDED.wire_protocol_version,
                sandbox_capable = EXCLUDED.sandbox_capable,
                sandbox_networking_capable = EXCLUDED.sandbox_networking_capable,
                tpm_capable = EXCLUDED.tpm_capable,
                resolver_capable = EXCLUDED.resolver_capable,
                metadata_service_capable = EXCLUDED.metadata_service_capable,
                dependency_observations = EXCLUDED.dependency_observations,
                dependency_observations_received_at = EXCLUDED.dependency_observations_received_at,
                organization_id = EXCLUDED.organization_id,
                organizational_unit_id = EXCLUDED.organizational_unit_id,
                auto_update = EXCLUDED.auto_update,
                update_desired_version = EXCLUDED.update_desired_version,
                update_assignment_source = EXCLUDED.update_assignment_source,
                update_artifact_override = EXCLUDED.update_artifact_override,
                update_attempted_at = EXCLUDED.update_attempted_at,
                update_blocked_reason = EXCLUDED.update_blocked_reason,
                update_failure_reason = EXCLUDED.update_failure_reason,
                teardown_refusal_reason = EXCLUDED.teardown_refusal_reason,
                teardown_refused_at = EXCLUDED.teardown_refused_at,
                manifest_status_reason = EXCLUDED.manifest_status_reason,
                manifest_status_at = EXCLUDED.manifest_status_at,
                manifest_inventory_complete = EXCLUDED.manifest_inventory_complete,
                updated_at = CURRENT_TIMESTAMP
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not persist agent")
        }
        return try row.agent
    }

    @discardableResult
    static func delete(id: UUID, on db: any Database) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM agents WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let name: String
        let trustDomain: String
        let hostname: String
        let version: String
        let statusRaw: String
        let totalCPU: Int
        let totalMemory: Int64
        let totalDisk: Int64
        let availableCPU: Int
        let availableMemory: Int64
        let availableDisk: Int64
        let lastHeartbeat: Date?
        let architecture: String?
        let operatingSystem: String?
        let hypervisorsJSON: String
        let networkCapability: String?
        let hostInfoJSON: String?
        let siteID: UUID
        let wireProtocolVersion: Int?
        let sandboxCapable: Bool
        let sandboxNetworkingCapable: Bool
        let tpmCapable: Bool
        let resolverCapable: Bool
        let metadataServiceCapable: Bool
        let dependencyObservationsJSON: String
        let dependencyObservationsReceivedAt: Date?
        let organizationID: UUID?
        let organizationalUnitID: UUID?
        let autoUpdate: Bool
        let updateDesiredVersion: String?
        let updateAssignmentSourceRaw: String?
        let updateArtifactOverrideJSON: String?
        let updateAttemptedAt: Date?
        let updateBlockedReason: String?
        let updateFailureReason: String?
        let teardownRefusalReason: String?
        let teardownRefusedAt: Date?
        let manifestStatusReason: String?
        let manifestStatusAt: Date?
        let manifestInventoryComplete: Bool?
        let createdAt: Date?
        let updatedAt: Date?

        var agent: Agent {
            get throws {
                guard let status = AgentStatus(rawValue: statusRaw) else {
                    throw Abort(.internalServerError, reason: "Agent has invalid status '\(statusRaw)'")
                }
                return Agent(
                    id: id,
                    name: name,
                    trustDomain: trustDomain,
                    hostname: hostname,
                    version: version,
                    status: status,
                    resources: AgentResources(
                        totalCPU: totalCPU, availableCPU: availableCPU,
                        totalMemory: totalMemory, availableMemory: availableMemory,
                        totalDisk: totalDisk, availableDisk: availableDisk),
                    architectureRaw: architecture,
                    operatingSystem: operatingSystem,
                    hypervisors: try decode([HypervisorSupport].self, hypervisorsJSON),
                    networkCapabilityRaw: networkCapability,
                    hostInfo: try decodeIfPresent(HostInfo.self, hostInfoJSON),
                    siteID: siteID,
                    wireProtocolVersion: wireProtocolVersion,
                    sandboxCapable: sandboxCapable,
                    sandboxNetworkingCapable: sandboxNetworkingCapable,
                    tpmCapable: tpmCapable,
                    resolverCapable: resolverCapable,
                    metadataServiceCapable: metadataServiceCapable,
                    dependencyObservations:
                        try decode([NodeDependencyObservation].self, dependencyObservationsJSON),
                    dependencyObservationsReceivedAt: dependencyObservationsReceivedAt,
                    organizationID: organizationID,
                    organizationalUnitID: organizationalUnitID,
                    autoUpdate: autoUpdate,
                    updateDesiredVersion: updateDesiredVersion,
                    updateAssignmentSourceRaw: updateAssignmentSourceRaw,
                    updateArtifactOverride:
                        try decodeIfPresent(ResolvedAgentArtifact.self, updateArtifactOverrideJSON),
                    updateAttemptedAt: updateAttemptedAt,
                    updateBlockedReason: updateBlockedReason,
                    updateFailureReason: updateFailureReason,
                    teardownRefusalReason: teardownRefusalReason,
                    teardownRefusedAt: teardownRefusedAt,
                    manifestStatusReason: manifestStatusReason,
                    manifestStatusAt: manifestStatusAt,
                    manifestInventoryComplete: manifestInventoryComplete,
                    lastHeartbeat: lastHeartbeat,
                    createdAt: createdAt,
                    updatedAt: updatedAt)
            }
        }
    }

    private static let columns = """
        a.id,
        a.name,
        a.trust_domain AS "trustDomain",
        a.hostname,
        a.version,
        a.status::text AS "statusRaw",
        a.total_cpu AS "totalCPU",
        a.total_memory AS "totalMemory",
        a.total_disk AS "totalDisk",
        a.available_cpu AS "availableCPU",
        a.available_memory AS "availableMemory",
        a.available_disk AS "availableDisk",
        a.last_heartbeat AS "lastHeartbeat",
        a.architecture,
        a.operating_system AS "operatingSystem",
        a.hypervisors::text AS "hypervisorsJSON",
        a.network_capability AS "networkCapability",
        a.host_info::text AS "hostInfoJSON",
        a.site_id AS "siteID",
        a.wire_protocol_version AS "wireProtocolVersion",
        a.sandbox_capable AS "sandboxCapable",
        a.sandbox_networking_capable AS "sandboxNetworkingCapable",
        a.tpm_capable AS "tpmCapable",
        a.resolver_capable AS "resolverCapable",
        a.metadata_service_capable AS "metadataServiceCapable",
        a.dependency_observations::text AS "dependencyObservationsJSON",
        a.dependency_observations_received_at AS "dependencyObservationsReceivedAt",
        a.organization_id AS "organizationID",
        a.organizational_unit_id AS "organizationalUnitID",
        a.auto_update AS "autoUpdate",
        a.update_desired_version AS "updateDesiredVersion",
        a.update_assignment_source AS "updateAssignmentSourceRaw",
        a.update_artifact_override::text AS "updateArtifactOverrideJSON",
        a.update_attempted_at AS "updateAttemptedAt",
        a.update_blocked_reason AS "updateBlockedReason",
        a.update_failure_reason AS "updateFailureReason",
        a.teardown_refusal_reason AS "teardownRefusalReason",
        a.teardown_refused_at AS "teardownRefusedAt",
        a.manifest_status_reason AS "manifestStatusReason",
        a.manifest_status_at AS "manifestStatusAt",
        a.manifest_inventory_complete AS "manifestInventoryComplete",
        a.created_at AS "createdAt",
        a.updated_at AS "updatedAt"
        """

    private static let returningColumns = columns.replacingOccurrences(of: "a.", with: "")

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func jsonIfPresent<T: Encodable>(_ value: T?) throws -> String? {
        guard let value else { return nil }
        return try json(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(value.utf8))
    }

    private static func decodeIfPresent<T: Decodable>(
        _ type: T.Type, _ value: String?
    ) throws -> T? {
        guard let value else { return nil }
        return try decode(T.self, value)
    }

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            throw Abort(.internalServerError, reason: "Agent compatibility access requires PostgreSQL")
        }
        return sql
    }
}
