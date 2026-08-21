import ControlPlanePostgres
import Foundation

/// Immutable decoding state for the last callers that must read floating-IP
/// rows through an existing Fluent transaction. Allocation, attachment,
/// release, and desired-state assembly use `FloatingIPAllocationsPersistence`.
struct LegacyFloatingIPRecord: Decodable, Equatable, Sendable {
    let id: UUID
    let poolID: UUID
    let address: String
    let projectID: UUID
    let interfaceID: UUID?
    let loadBalancerID: UUID?
    let createdByID: UUID?
    let createdAt: Date?
    let updatedAt: Date?
}

enum LegacyFloatingIPStore {
    private static let columns = """
        id, pool_id AS "poolID", address, project_id AS "projectID",
        interface_id AS "interfaceID", load_balancer_id AS "loadBalancerID",
        created_by_id AS "createdByID", created_at AS "createdAt",
        updated_at AS "updatedAt"
        """

    static func find(id: UUID, on db: PostgresStoreContext) async throws -> LegacyFloatingIPRecord? {
        try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM floating_ips WHERE id = \(bind: id)"
        ).first(decoding: LegacyFloatingIPRecord.self)
    }

    static func rows(ids: [UUID], on db: PostgresStoreContext) async throws -> [LegacyFloatingIPRecord] {
        guard !ids.isEmpty else { return [] }
        return try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM floating_ips WHERE id = ANY(\(bind: ids)) ORDER BY id"
        ).all(decoding: LegacyFloatingIPRecord.self)
    }

    static func ids(projectIDs: [UUID], on db: PostgresStoreContext) async throws -> [UUID] {
        struct Identifier: Decodable { let id: UUID }
        guard !projectIDs.isEmpty else { return [] }
        return try await requireSQL(db).raw(
            "SELECT id FROM floating_ips WHERE project_id = ANY(\(bind: projectIDs)) ORDER BY id"
        ).all(decoding: Identifier.self).map(\.id)
    }

    static func attachedInterfaceCount(networkID: UUID, on db: PostgresStoreContext) async throws -> Int {
        struct CountRow: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            """
            SELECT count(*)::bigint AS count
            FROM floating_ips AS floating_ip
            JOIN vm_network_interfaces AS interface
              ON interface.id = floating_ip.interface_id
            WHERE interface.logical_network_id = \(bind: networkID)
            """
        ).first(decoding: CountRow.self)?.count ?? 0
    }

    @discardableResult
    static func insert(
        id: UUID = UUID(),
        poolID: UUID,
        address: String,
        projectID: UUID,
        interfaceID: UUID? = nil,
        loadBalancerID: UUID? = nil,
        createdByID: UUID? = nil,
        on db: PostgresStoreContext
    ) async throws -> LegacyFloatingIPRecord {
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO floating_ips (
                id, pool_id, address, project_id, interface_id,
                load_balancer_id, created_by_id, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: poolID), \(bind: address), \(bind: projectID),
                \(bind: interfaceID), \(bind: loadBalancerID), \(bind: createdByID),
                CURRENT_TIMESTAMP, NULL
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: LegacyFloatingIPRecord.self) else {
            throw FloatingIPAllocationError.unexpectedRowCount(expected: 1, actual: 0)
        }
        return row
    }

    @discardableResult
    static func setAttachment(
        id: UUID,
        interfaceID: UUID?,
        loadBalancerID: UUID?,
        on db: PostgresStoreContext
    ) async throws -> LegacyFloatingIPRecord? {
        try await requireSQL(db).raw(
            """
            UPDATE floating_ips
            SET interface_id = \(bind: interfaceID),
                load_balancer_id = \(bind: loadBalancerID),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: id)
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: LegacyFloatingIPRecord.self)
    }

    private static func requireSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
        guard let sql = db as? PostgresStoreContext else {
            throw FloatingIPAllocationError.unexpectedRowCount(expected: 1, actual: 0)
        }
        return sql
    }
}
