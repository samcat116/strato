import ControlPlanePostgres
import Foundation
import Vapor

/// Fixed-shape quota access for operations that still own a Fluent transaction.
/// The returned values are immutable and every write is explicit.
enum LegacyResourceQuotaStore {
    static func quota(id: UUID?, on db: PostgresStoreContext) async throws -> ResourceQuota? {
        guard let id else { return nil }
        let rows = try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM resource_quotas AS q WHERE q.id = \(bind: id)"
        ).all(decoding: Record.self)
        guard rows.count <= 1 else {
            throw Abort(.internalServerError, reason: "Resource quota lookup returned duplicate rows")
        }
        return rows.first?.quota
    }

    static func all(on db: PostgresStoreContext) async throws -> [ResourceQuota] {
        try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM resource_quotas AS q ORDER BY q.created_at, q.id"
        ).all(decoding: Record.self).map(\.quota)
    }

    static func quotas(name: String, on db: PostgresStoreContext) async throws -> [ResourceQuota] {
        try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM resource_quotas AS q WHERE q.name = \(bind: name) ORDER BY q.id"
        ).all(decoding: Record.self).map(\.quota)
    }

    static func applicable(
        projectID: UUID,
        organizationalUnitIDs: [UUID],
        organizationID: UUID?,
        environment: String?,
        on db: PostgresStoreContext
    ) async throws -> [ResourceQuota] {
        var query: PostgresSQLQuery = "SELECT \(unsafeRaw: columns) FROM resource_quotas AS q WHERE (q.project_id = \(bind: projectID)"
        if !organizationalUnitIDs.isEmpty {
            query += " OR q.organizational_unit_id = ANY(\(bind: organizationalUnitIDs))"
        }
        if let organizationID {
            query += " OR q.organization_id = \(bind: organizationID)"
        }
        query += ")"
        if let environment {
            query += " AND (q.environment IS NULL OR q.environment = \(bind: environment))"
        } else {
            query += " AND q.environment IS NULL"
        }
        query += " ORDER BY q.id"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map(\.quota)
    }

    static func hierarchy(
        organizationID: UUID,
        organizationalUnitIDs: [UUID],
        projectIDs: [UUID],
        on db: PostgresStoreContext
    ) async throws -> [ResourceQuota] {
        var query: PostgresSQLQuery = "SELECT \(unsafeRaw: columns) FROM resource_quotas AS q WHERE q.organization_id = \(bind: organizationID)"
        if !organizationalUnitIDs.isEmpty {
            query += " OR q.organizational_unit_id = ANY(\(bind: organizationalUnitIDs))"
        }
        if !projectIDs.isEmpty {
            query += " OR q.project_id = ANY(\(bind: projectIDs))"
        }
        query += " ORDER BY q.created_at, q.id"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map(\.quota)
    }

    @discardableResult
    static func upsert(_ quota: ResourceQuota, on db: PostgresStoreContext) async throws -> ResourceQuota {
        let id = try quota.requireID()
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO resource_quotas (
                id, name, organization_id, organizational_unit_id, project_id,
                max_vcpus, reserved_vcpus, max_memory, reserved_memory,
                max_storage, reserved_storage, max_vms, vm_count,
                max_sandboxes, sandbox_count, max_volumes, volume_count,
                max_networks, network_count, max_load_balancers, load_balancer_count,
                is_enabled, environment, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: quota.name), \(bind: quota.organizationID),
                \(bind: quota.organizationalUnitID), \(bind: quota.projectID),
                \(bind: quota.maxVCPUs), \(bind: quota.reservedVCPUs),
                \(bind: quota.maxMemory), \(bind: quota.reservedMemory),
                \(bind: quota.maxStorage), \(bind: quota.reservedStorage),
                \(bind: quota.maxVMs), \(bind: quota.vmCount),
                \(bind: quota.maxSandboxes), \(bind: quota.sandboxCount),
                \(bind: quota.maxVolumes), \(bind: quota.volumeCount),
                \(bind: quota.maxNetworks), \(bind: quota.networkCount),
                \(bind: quota.maxLoadBalancers), \(bind: quota.loadBalancerCount),
                \(bind: quota.isEnabled), \(bind: quota.environment),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name,
                organization_id = EXCLUDED.organization_id,
                organizational_unit_id = EXCLUDED.organizational_unit_id,
                project_id = EXCLUDED.project_id,
                max_vcpus = EXCLUDED.max_vcpus,
                reserved_vcpus = EXCLUDED.reserved_vcpus,
                max_memory = EXCLUDED.max_memory,
                reserved_memory = EXCLUDED.reserved_memory,
                max_storage = EXCLUDED.max_storage,
                reserved_storage = EXCLUDED.reserved_storage,
                max_vms = EXCLUDED.max_vms,
                vm_count = EXCLUDED.vm_count,
                max_sandboxes = EXCLUDED.max_sandboxes,
                sandbox_count = EXCLUDED.sandbox_count,
                max_volumes = EXCLUDED.max_volumes,
                volume_count = EXCLUDED.volume_count,
                max_networks = EXCLUDED.max_networks,
                network_count = EXCLUDED.network_count,
                max_load_balancers = EXCLUDED.max_load_balancers,
                load_balancer_count = EXCLUDED.load_balancer_count,
                is_enabled = EXCLUDED.is_enabled,
                environment = EXCLUDED.environment,
                updated_at = CURRENT_TIMESTAMP
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not persist resource quota")
        }
        return row.quota
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let name: String
        let organizationID: UUID?
        let organizationalUnitID: UUID?
        let projectID: UUID?
        let maxVCPUs: Int
        let reservedVCPUs: Int
        let maxMemory: Int64
        let reservedMemory: Int64
        let maxStorage: Int64
        let reservedStorage: Int64
        let maxVMs: Int
        let vmCount: Int
        let maxSandboxes: Int
        let sandboxCount: Int
        let maxVolumes: Int?
        let volumeCount: Int
        let maxNetworks: Int
        let networkCount: Int
        let maxLoadBalancers: Int
        let loadBalancerCount: Int
        let isEnabled: Bool
        let environment: String?
        let createdAt: Date?
        let updatedAt: Date?

        var quota: ResourceQuota {
            ResourceQuota(
                id: id, name: name,
                organizationID: organizationID,
                organizationalUnitID: organizationalUnitID,
                projectID: projectID,
                maxVCPUs: maxVCPUs, maxMemory: maxMemory,
                maxStorage: maxStorage, maxVMs: maxVMs,
                maxSandboxes: maxSandboxes, maxVolumes: maxVolumes,
                maxNetworks: maxNetworks, maxLoadBalancers: maxLoadBalancers,
                environment: environment, isEnabled: isEnabled,
                reservedVCPUs: reservedVCPUs, reservedMemory: reservedMemory,
                reservedStorage: reservedStorage, vmCount: vmCount,
                sandboxCount: sandboxCount, volumeCount: volumeCount,
                networkCount: networkCount, loadBalancerCount: loadBalancerCount,
                createdAt: createdAt, updatedAt: updatedAt)
        }
    }

    private static let columns = """
        q.id,
        q.name,
        q.organization_id AS "organizationID",
        q.organizational_unit_id AS "organizationalUnitID",
        q.project_id AS "projectID",
        q.max_vcpus AS "maxVCPUs",
        q.reserved_vcpus AS "reservedVCPUs",
        q.max_memory AS "maxMemory",
        q.reserved_memory AS "reservedMemory",
        q.max_storage AS "maxStorage",
        q.reserved_storage AS "reservedStorage",
        q.max_vms AS "maxVMs",
        q.vm_count AS "vmCount",
        q.max_sandboxes AS "maxSandboxes",
        q.sandbox_count AS "sandboxCount",
        q.max_volumes AS "maxVolumes",
        q.volume_count AS "volumeCount",
        q.max_networks AS "maxNetworks",
        q.network_count AS "networkCount",
        q.max_load_balancers AS "maxLoadBalancers",
        q.load_balancer_count AS "loadBalancerCount",
        q.is_enabled AS "isEnabled",
        q.environment,
        q.created_at AS "createdAt",
        q.updated_at AS "updatedAt"
        """

    private static let returningColumns = """
        id,
        name,
        organization_id AS "organizationID",
        organizational_unit_id AS "organizationalUnitID",
        project_id AS "projectID",
        max_vcpus AS "maxVCPUs",
        reserved_vcpus AS "reservedVCPUs",
        max_memory AS "maxMemory",
        reserved_memory AS "reservedMemory",
        max_storage AS "maxStorage",
        reserved_storage AS "reservedStorage",
        max_vms AS "maxVMs",
        vm_count AS "vmCount",
        max_sandboxes AS "maxSandboxes",
        sandbox_count AS "sandboxCount",
        max_volumes AS "maxVolumes",
        volume_count AS "volumeCount",
        max_networks AS "maxNetworks",
        network_count AS "networkCount",
        max_load_balancers AS "maxLoadBalancers",
        load_balancer_count AS "loadBalancerCount",
        is_enabled AS "isEnabled",
        environment,
        created_at AS "createdAt",
        updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
        guard let sql = db as? PostgresStoreContext, sql.dialect.name == "postgresql" else {
            throw Abort(.internalServerError, reason: "Quota compatibility access requires PostgreSQL")
        }
        return sql
    }
}
