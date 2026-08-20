import Foundation
import PostgresNIO

public struct ResourceQuotaSnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let organizationID: UUID?
    public let organizationalUnitID: UUID?
    public let projectID: UUID?
    public let maxVCPUs: Int
    public let reservedVCPUs: Int
    public let maxMemory: Int64
    public let reservedMemory: Int64
    public let maxStorage: Int64
    public let reservedStorage: Int64
    public let maxVMs: Int
    public let vmCount: Int
    public let maxSandboxes: Int
    public let sandboxCount: Int
    public let maxVolumes: Int?
    public let volumeCount: Int
    public let maxNetworks: Int
    public let networkCount: Int
    public let maxLoadBalancers: Int
    public let loadBalancerCount: Int
    public let isEnabled: Bool
    public let environment: String?
    public let createdAt: Date?
    public let updatedAt: Date?
}

public struct ResourceQuotaWrite: Sendable {
    public let id: UUID
    public let name: String
    public let organizationID: UUID?
    public let organizationalUnitID: UUID?
    public let projectID: UUID?
    public let maxVCPUs: Int
    public let maxMemory: Int64
    public let maxStorage: Int64
    public let maxVMs: Int
    public let maxSandboxes: Int
    public let maxVolumes: Int?
    public let maxNetworks: Int
    public let maxLoadBalancers: Int
    public let isEnabled: Bool
    public let environment: String?

    public init(
        id: UUID = UUID(),
        name: String,
        organizationID: UUID?,
        organizationalUnitID: UUID?,
        projectID: UUID?,
        maxVCPUs: Int,
        maxMemory: Int64,
        maxStorage: Int64,
        maxVMs: Int,
        maxSandboxes: Int,
        maxVolumes: Int?,
        maxNetworks: Int,
        maxLoadBalancers: Int,
        isEnabled: Bool,
        environment: String?
    ) {
        self.id = id
        self.name = name
        self.organizationID = organizationID
        self.organizationalUnitID = organizationalUnitID
        self.projectID = projectID
        self.maxVCPUs = maxVCPUs
        self.maxMemory = maxMemory
        self.maxStorage = maxStorage
        self.maxVMs = maxVMs
        self.maxSandboxes = maxSandboxes
        self.maxVolumes = maxVolumes
        self.maxNetworks = maxNetworks
        self.maxLoadBalancers = maxLoadBalancers
        self.isEnabled = isEnabled
        self.environment = environment
    }
}

public struct ResourceQuotaMeasuredUsage: Equatable, Sendable {
    public let vcpus: Int
    public let memoryBytes: Int64
    public let storageBytes: Int64
    public let vmCount: Int
    public let sandboxCount: Int
    public let volumeCount: Int
    public let networkCount: Int
    public let loadBalancerCount: Int

    public var isEmpty: Bool {
        vcpus == 0 && memoryBytes == 0 && storageBytes == 0 && vmCount == 0
            && sandboxCount == 0 && volumeCount == 0 && networkCount == 0
            && loadBalancerCount == 0
    }
}

public struct ResourceQuotaUsageSnapshot: Equatable, Sendable {
    public let usage: ResourceQuotaMeasuredUsage
    public let vmsByEnvironment: [String: Int]
    public let vmsByStatus: [String: Int]
}

public enum ResourceQuotaPersistenceError: Error, Equatable, Sendable {
    case duplicateName
    case invalidScope
    case notFound
    case unexpectedRowCount(expected: Int, actual: Int)
}

public struct ResourceQuotasPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func quota(id: UUID) async throws -> ResourceQuotaSnapshot? {
        try await database.withSession(operation: "quotas.lookup") { session in
            try oneOrNone(
                await session.execute(FindResourceQuota(id: id), operation: "quotas.lookup.query")
            )
        }
    }

    public func quotas(organizationID: UUID) async throws -> [ResourceQuotaSnapshot] {
        try await list(scopeType: "organization", scopeID: organizationID)
    }

    public func quotas(organizationalUnitID: UUID) async throws -> [ResourceQuotaSnapshot] {
        try await list(scopeType: "organizational_unit", scopeID: organizationalUnitID)
    }

    public func quotas(projectID: UUID) async throws -> [ResourceQuotaSnapshot] {
        try await list(scopeType: "project", scopeID: projectID)
    }

    public func visibleCandidates(
        organizationIDs: [UUID],
        organizationalUnitIDs: [UUID],
        projectIDs: [UUID]?,
        level: String?
    ) async throws -> [ResourceQuotaSnapshot] {
        if organizationIDs.isEmpty, organizationalUnitIDs.isEmpty,
            let projectIDs, projectIDs.isEmpty
        { return [] }
        return try await database.withSession(operation: "quotas.list_visible_candidates") { session in
            try await session.execute(
                ListVisibleQuotaCandidates(
                    organizationIDs: Array(Set(organizationIDs)),
                    organizationalUnitIDs: Array(Set(organizationalUnitIDs)),
                    projectIDs: projectIDs.map { Array(Set($0)) },
                    level: level
                ),
                operation: "quotas.list_visible_candidates.query"
            )
        }
    }

    public func nameExists(
        name: String,
        organizationID: UUID?,
        organizationalUnitID: UUID?,
        projectID: UUID?,
        environment: String?,
        excluding id: UUID? = nil
    ) async throws -> Bool {
        try await database.withSession(operation: "quotas.name_exists") { session in
            try only(
                await session.execute(
                    ResourceQuotaNameExists(
                        name: name,
                        organizationID: organizationID,
                        organizationalUnitID: organizationalUnitID,
                        projectID: projectID,
                        environment: environment,
                        excludedID: id
                    ),
                    operation: "quotas.name_exists.query"
                )
            )
        }
    }

    public func create(_ write: ResourceQuotaWrite) async throws -> ResourceQuotaSnapshot {
        try validateScope(write)
        do {
            return try await database.withTransaction(operation: "quotas.create") { session in
                guard
                    !(try only(
                        await session.execute(
                            ResourceQuotaNameExists(
                                name: write.name,
                                organizationID: write.organizationID,
                                organizationalUnitID: write.organizationalUnitID,
                                projectID: write.projectID,
                                environment: write.environment,
                                excludedID: nil
                            ),
                            operation: "quotas.create.name_exists"
                        )
                    ))
                else { throw ResourceQuotaPersistenceError.duplicateName }
                let usage = try only(
                    await session.execute(
                        MeasureResourceQuotaScope(scope: .init(write)),
                        operation: "quotas.create.measure"
                    )
                )
                return try only(
                    await session.execute(
                        InsertResourceQuota(write: write, usage: usage),
                        operation: "quotas.create.insert"
                    )
                )
            }
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
            throw ResourceQuotaPersistenceError.duplicateName
        }
    }

    public func replace(
        _ write: ResourceQuotaWrite,
        usage: ResourceQuotaMeasuredUsage
    ) async throws -> ResourceQuotaSnapshot? {
        try validateScope(write)
        do {
            return try await database.withSession(operation: "quotas.replace") { session in
                try oneOrNone(
                    await session.execute(
                        ReplaceResourceQuota(write: write, usage: usage),
                        operation: "quotas.replace.query"
                    )
                )
            }
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
            throw ResourceQuotaPersistenceError.duplicateName
        }
    }

    public func measure(_ quota: ResourceQuotaSnapshot) async throws -> ResourceQuotaMeasuredUsage {
        try await database.withSession(operation: "quotas.measure") { session in
            try only(
                await session.execute(
                    MeasureResourceQuotaScope(scope: .init(quota)),
                    operation: "quotas.measure.query"
                )
            )
        }
    }

    public func usage(_ quota: ResourceQuotaSnapshot) async throws -> ResourceQuotaUsageSnapshot {
        try await database.withSession(operation: "quotas.usage") { session in
            let scope = ResourceQuotaScopeReference(quota)
            let measured = try only(
                await session.execute(
                    MeasureResourceQuotaScope(scope: scope),
                    operation: "quotas.usage.measure"
                )
            )
            let rows = try await session.execute(
                ResourceQuotaVMBreakdown(scope: scope),
                operation: "quotas.usage.vm_breakdown"
            )
            var environments: [String: Int] = [:]
            var statuses: [String: Int] = [:]
            for row in rows {
                environments[row.environment, default: 0] += row.count
                statuses[row.status, default: 0] += row.count
            }
            return ResourceQuotaUsageSnapshot(
                usage: measured,
                vmsByEnvironment: environments,
                vmsByStatus: statuses
            )
        }
    }

    public func deleteIfUnused(id: UUID) async throws -> Bool {
        try await database.withTransaction(operation: "quotas.delete_if_unused") { session in
            guard
                let quota = try oneOrNone(
                    await session.execute(
                        LockResourceQuota(id: id),
                        operation: "quotas.delete_if_unused.lock"
                    )
                )
            else { throw ResourceQuotaPersistenceError.notFound }
            let usage = try only(
                await session.execute(
                    MeasureResourceQuotaScope(scope: .init(quota)),
                    operation: "quotas.delete_if_unused.measure"
                )
            )
            guard usage.isEmpty else { return false }
            return try await session.execute(
                DeleteResourceQuota(id: id),
                operation: "quotas.delete_if_unused.delete"
            ).count == 1
        }
    }

    private func list(scopeType: String, scopeID: UUID) async throws -> [ResourceQuotaSnapshot] {
        try await database.withSession(operation: "quotas.list_scope") { session in
            try await session.execute(
                ListResourceQuotas(scopeType: scopeType, scopeID: scopeID),
                operation: "quotas.list_scope.query"
            )
        }
    }

    private func validateScope(_ write: ResourceQuotaWrite) throws {
        guard [write.organizationID, write.organizationalUnitID, write.projectID]
            .compactMap({ $0 }).count == 1
        else { throw ResourceQuotaPersistenceError.invalidScope }
    }

    private func oneOrNone<T>(_ rows: [T]) throws -> T? {
        guard rows.count <= 1 else {
            throw ResourceQuotaPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first
    }

    private func only<T>(_ rows: [T]) throws -> T {
        guard rows.count == 1, let value = rows.first else {
            throw ResourceQuotaPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return value
    }
}

let resourceQuotaColumns = """
    id, name, organization_id, organizational_unit_id, project_id,
    max_vcpus, reserved_vcpus, max_memory, reserved_memory,
    max_storage, reserved_storage, max_vms, vm_count,
    max_sandboxes, sandbox_count, max_volumes, volume_count,
    max_networks, network_count, max_load_balancers, load_balancer_count,
    is_enabled, environment, created_at, updated_at
    """

protocol ResourceQuotaStatement: PostgresPreparedStatement
    where Row == ResourceQuotaSnapshot {}

extension ResourceQuotaStatement {
    func decodeRow(_ row: PostgresRow) throws -> ResourceQuotaSnapshot {
        let value = try row.decode(
            (UUID, String, UUID?, UUID?, UUID?, Int, Int, Int64, Int64, Int64, Int64,
             Int, Int, Int, Int, Int?, Int, Int, Int, Int, Int, Bool, String?, Date?, Date?).self
        )
        return ResourceQuotaSnapshot(
            id: value.0, name: value.1, organizationID: value.2,
            organizationalUnitID: value.3, projectID: value.4,
            maxVCPUs: value.5, reservedVCPUs: value.6,
            maxMemory: value.7, reservedMemory: value.8,
            maxStorage: value.9, reservedStorage: value.10,
            maxVMs: value.11, vmCount: value.12,
            maxSandboxes: value.13, sandboxCount: value.14,
            maxVolumes: value.15, volumeCount: value.16,
            maxNetworks: value.17, networkCount: value.18,
            maxLoadBalancers: value.19, loadBalancerCount: value.20,
            isEnabled: value.21, environment: value.22,
            createdAt: value.23, updatedAt: value.24
        )
    }
}

private struct FindResourceQuota: ResourceQuotaStatement {
    static let sql = "SELECT \(resourceQuotaColumns) FROM resource_quotas WHERE id = $1"
    let id: UUID
    func makeBindings() -> PostgresBindings { bindings(id) }
}

private struct LockResourceQuota: ResourceQuotaStatement {
    static let sql = "SELECT \(resourceQuotaColumns) FROM resource_quotas WHERE id = $1 FOR UPDATE"
    let id: UUID
    func makeBindings() -> PostgresBindings { bindings(id) }
}

private struct ListResourceQuotas: ResourceQuotaStatement {
    static let sql = """
        SELECT \(resourceQuotaColumns)
        FROM resource_quotas
        WHERE CASE $1
            WHEN 'organization' THEN organization_id = $2
            WHEN 'organizational_unit' THEN organizational_unit_id = $2
            WHEN 'project' THEN project_id = $2
            ELSE FALSE
        END
        ORDER BY name, id
        """
    let scopeType: String
    let scopeID: UUID
    func makeBindings() -> PostgresBindings { bindings(scopeType, scopeID) }
}

private struct ListVisibleQuotaCandidates: ResourceQuotaStatement {
    static let sql = """
        SELECT \(resourceQuotaColumns)
        FROM resource_quotas
        WHERE (
            organization_id = ANY($1::uuid[])
            OR organizational_unit_id = ANY($2::uuid[])
            OR ($3::uuid[] IS NULL AND project_id IS NOT NULL)
            OR project_id = ANY(COALESCE($3::uuid[], ARRAY[]::uuid[]))
        )
        AND CASE $4::text
            WHEN 'organization' THEN organization_id IS NOT NULL
                AND organizational_unit_id IS NULL AND project_id IS NULL
            WHEN 'organizational_unit' THEN organizational_unit_id IS NOT NULL AND project_id IS NULL
            WHEN 'project' THEN project_id IS NOT NULL
            ELSE TRUE
        END
        ORDER BY name, id
        """
    let organizationIDs: [UUID]
    let organizationalUnitIDs: [UUID]
    let projectIDs: [UUID]?
    let level: String?
    func makeBindings() throws -> PostgresBindings {
        var result = PostgresBindings(capacity: 4)
        result.append(organizationIDs)
        result.append(organizationalUnitIDs)
        result.append(projectIDs)
        result.append(level)
        return result
    }
}

private struct ResourceQuotaNameExists: PostgresPreparedStatement {
    static let sql = """
        SELECT EXISTS (
            SELECT 1 FROM resource_quotas
            WHERE name = $1
              AND organization_id IS NOT DISTINCT FROM $2
              AND organizational_unit_id IS NOT DISTINCT FROM $3
              AND project_id IS NOT DISTINCT FROM $4
              AND environment IS NOT DISTINCT FROM $5
              AND ($6::uuid IS NULL OR id <> $6)
        )
        """
    typealias Row = Bool
    let name: String
    let organizationID: UUID?
    let organizationalUnitID: UUID?
    let projectID: UUID?
    let environment: String?
    let excludedID: UUID?
    func makeBindings() -> PostgresBindings {
        var result = PostgresBindings(capacity: 6)
        result.append(name)
        result.append(organizationID)
        result.append(organizationalUnitID)
        result.append(projectID)
        result.append(environment)
        result.append(excludedID)
        return result
    }
    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

struct ResourceQuotaScopeReference: Sendable {
    let type: String
    let id: UUID
    let environment: String?

    init(_ quota: ResourceQuotaSnapshot) {
        if let id = quota.projectID { type = "project"; self.id = id }
        else if let id = quota.organizationalUnitID { type = "organizational_unit"; self.id = id }
        else if let id = quota.organizationID { type = "organization"; self.id = id }
        else { type = "none"; id = UUID() }
        environment = quota.environment
    }

    init(_ write: ResourceQuotaWrite) {
        if let id = write.projectID { type = "project"; self.id = id }
        else if let id = write.organizationalUnitID { type = "organizational_unit"; self.id = id }
        else if let id = write.organizationID { type = "organization"; self.id = id }
        else { type = "none"; id = UUID() }
        environment = write.environment
    }

    init(type: String, id: UUID, environment: String?) {
        self.type = type
        self.id = id
        self.environment = environment
    }
}

struct MeasureResourceQuotaScope: PostgresPreparedStatement {
    static let sql = """
        WITH scoped_projects AS (
            SELECT p.id
            FROM projects AS p
            LEFT JOIN organizational_units AS ou ON ou.id = p.organizational_unit_id
            WHERE CASE $1
                WHEN 'project' THEN p.id = $2
                WHEN 'organizational_unit' THEN p.organizational_unit_id IN (
                    SELECT child.id
                    FROM organizational_units AS root
                    JOIN organizational_units AS child
                      ON child.path = root.path OR child.path LIKE root.path || '/%'
                    WHERE root.id = $2
                )
                WHEN 'organization' THEN p.organization_id = $2 OR ou.organization_id = $2
                ELSE FALSE
            END
        )
        SELECT
          (SELECT COALESCE(SUM(cpu), 0)::bigint FROM vms
           WHERE project_id IN (SELECT id FROM scoped_projects)
             AND ($3::text IS NULL OR environment = $3))
          +
          (SELECT COALESCE(SUM(vcpus), 0)::bigint FROM sandboxes
           WHERE project_id IN (SELECT id FROM scoped_projects)
             AND ($3::text IS NULL OR environment = $3)) AS vcpus,
          (SELECT COALESCE(SUM(memory), 0)::bigint FROM vms
           WHERE project_id IN (SELECT id FROM scoped_projects)
             AND ($3::text IS NULL OR environment = $3))
          +
          (SELECT COALESCE(SUM(memory), 0)::bigint FROM sandboxes
           WHERE project_id IN (SELECT id FROM scoped_projects)
             AND ($3::text IS NULL OR environment = $3)) AS memory_bytes,
          (SELECT COALESCE(SUM(size), 0)::bigint FROM volumes
           WHERE project_id IN (SELECT id FROM scoped_projects)
             AND ($3::text IS NULL OR environment = $3))
          +
          (SELECT COALESCE(SUM(size), 0)::bigint FROM volume_snapshots
           WHERE project_id IN (SELECT id FROM scoped_projects)
             AND ($3::text IS NULL OR environment = $3) AND status::text <> 'error')
          +
          (SELECT COALESCE(SUM(size), 0)::bigint FROM vm_snapshots
           WHERE project_id IN (SELECT id FROM scoped_projects)
             AND ($3::text IS NULL OR environment = $3) AND status::text <> 'error')
          +
          (SELECT COALESCE(SUM(size), 0)::bigint
             + COALESCE(SUM((
                 SELECT COALESCE(SUM((artifact->>'sizeBytes')::bigint), 0)
                 FROM unnest(exported_artifacts) AS artifact
               )), 0)::bigint
           FROM sandbox_snapshots
           WHERE project_id IN (SELECT id FROM scoped_projects)
             AND ($3::text IS NULL OR environment = $3) AND status::text <> 'error')
          AS storage_bytes,
          (SELECT COUNT(*)::bigint FROM vms
           WHERE project_id IN (SELECT id FROM scoped_projects)
             AND ($3::text IS NULL OR environment = $3)) AS vm_count,
          (SELECT COUNT(*)::bigint FROM sandboxes
           WHERE project_id IN (SELECT id FROM scoped_projects)
             AND ($3::text IS NULL OR environment = $3)) AS sandbox_count,
          (SELECT COUNT(*)::bigint FROM volumes
           WHERE project_id IN (SELECT id FROM scoped_projects)
             AND ($3::text IS NULL OR environment = $3)) AS volume_count,
          (SELECT COUNT(*)::bigint FROM logical_networks
           WHERE project_id IN (SELECT id FROM scoped_projects) AND $3::text IS NULL) AS network_count,
          (SELECT COUNT(*)::bigint FROM load_balancers
           WHERE project_id IN (SELECT id FROM scoped_projects) AND $3::text IS NULL) AS load_balancer_count
        """
    typealias Row = ResourceQuotaMeasuredUsage
    let scope: ResourceQuotaScopeReference
    func makeBindings() -> PostgresBindings {
        var result = PostgresBindings(capacity: 3)
        result.append(scope.type)
        result.append(scope.id)
        result.append(scope.environment)
        return result
    }
    func decodeRow(_ row: PostgresRow) throws -> ResourceQuotaMeasuredUsage {
        let value = try row.decode((Int, Int64, Int64, Int, Int, Int, Int, Int).self)
        return ResourceQuotaMeasuredUsage(
            vcpus: value.0, memoryBytes: value.1, storageBytes: value.2,
            vmCount: value.3, sandboxCount: value.4, volumeCount: value.5,
            networkCount: value.6, loadBalancerCount: value.7
        )
    }
}

private struct InsertResourceQuota: ResourceQuotaStatement {
    static let sql = """
        INSERT INTO resource_quotas (
            id, name, organization_id, organizational_unit_id, project_id,
            max_vcpus, reserved_vcpus, max_memory, reserved_memory,
            max_storage, reserved_storage, max_vms, vm_count,
            max_sandboxes, sandbox_count, max_volumes, volume_count,
            max_networks, network_count, max_load_balancers, load_balancer_count,
            is_enabled, environment, created_at, updated_at
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
            $14, $15, $16, $17, $18, $19, $20, $21, $22, $23,
            CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        )
        RETURNING \(resourceQuotaColumns)
        """
    let write: ResourceQuotaWrite
    let usage: ResourceQuotaMeasuredUsage
    func makeBindings() -> PostgresBindings { quotaBindings(write: write, usage: usage) }
}

private struct ReplaceResourceQuota: ResourceQuotaStatement {
    static let sql = """
        UPDATE resource_quotas SET
            name = $2, organization_id = $3, organizational_unit_id = $4, project_id = $5,
            max_vcpus = $6, reserved_vcpus = $7, max_memory = $8, reserved_memory = $9,
            max_storage = $10, reserved_storage = $11, max_vms = $12, vm_count = $13,
            max_sandboxes = $14, sandbox_count = $15, max_volumes = $16, volume_count = $17,
            max_networks = $18, network_count = $19,
            max_load_balancers = $20, load_balancer_count = $21,
            is_enabled = $22, environment = $23, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(resourceQuotaColumns)
        """
    let write: ResourceQuotaWrite
    let usage: ResourceQuotaMeasuredUsage
    func makeBindings() -> PostgresBindings { quotaBindings(write: write, usage: usage) }
}

private func quotaBindings(
    write: ResourceQuotaWrite,
    usage: ResourceQuotaMeasuredUsage
) -> PostgresBindings {
    var result = PostgresBindings(capacity: 23)
    result.append(write.id); result.append(write.name)
    result.append(write.organizationID); result.append(write.organizationalUnitID); result.append(write.projectID)
    result.append(write.maxVCPUs); result.append(usage.vcpus)
    result.append(write.maxMemory); result.append(usage.memoryBytes)
    result.append(write.maxStorage); result.append(usage.storageBytes)
    result.append(write.maxVMs); result.append(usage.vmCount)
    result.append(write.maxSandboxes); result.append(usage.sandboxCount)
    result.append(write.maxVolumes); result.append(usage.volumeCount)
    result.append(write.maxNetworks); result.append(usage.networkCount)
    result.append(write.maxLoadBalancers); result.append(usage.loadBalancerCount)
    result.append(write.isEnabled); result.append(write.environment)
    return result
}

private struct ResourceQuotaVMBreakdownRow: Sendable {
    let environment: String
    let status: String
    let count: Int
}

private struct ResourceQuotaVMBreakdown: PostgresPreparedStatement {
    static let sql = """
        WITH scoped_projects AS (
            SELECT p.id
            FROM projects AS p
            LEFT JOIN organizational_units AS ou ON ou.id = p.organizational_unit_id
            WHERE CASE $1
                WHEN 'project' THEN p.id = $2
                WHEN 'organizational_unit' THEN p.organizational_unit_id IN (
                    SELECT child.id FROM organizational_units AS root
                    JOIN organizational_units AS child
                      ON child.path = root.path OR child.path LIKE root.path || '/%'
                    WHERE root.id = $2
                )
                WHEN 'organization' THEN p.organization_id = $2 OR ou.organization_id = $2
                ELSE FALSE
            END
        )
        SELECT environment, status::text, COUNT(*)::bigint
        FROM vms
        WHERE project_id IN (SELECT id FROM scoped_projects)
          AND ($3::text IS NULL OR environment = $3)
        GROUP BY environment, status
        """
    typealias Row = ResourceQuotaVMBreakdownRow
    let scope: ResourceQuotaScopeReference
    func makeBindings() -> PostgresBindings {
        var result = PostgresBindings(capacity: 3)
        result.append(scope.type); result.append(scope.id); result.append(scope.environment)
        return result
    }
    func decodeRow(_ row: PostgresRow) throws -> ResourceQuotaVMBreakdownRow {
        let value = try row.decode((String, String, Int).self)
        return ResourceQuotaVMBreakdownRow(environment: value.0, status: value.1, count: value.2)
    }
}

private struct DeleteResourceQuota: PostgresPreparedStatement {
    static let sql = "DELETE FROM resource_quotas WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings { bindings(id) }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private func bindings<T: PostgresNonThrowingEncodable & Sendable>(_ value: T) -> PostgresBindings {
    var result = PostgresBindings(capacity: 1)
    result.append(value)
    return result
}

private func bindings<First: PostgresNonThrowingEncodable & Sendable, Second: PostgresNonThrowingEncodable & Sendable>(
    _ first: First,
    _ second: Second
) -> PostgresBindings {
    var result = PostgresBindings(capacity: 2)
    result.append(first); result.append(second)
    return result
}
