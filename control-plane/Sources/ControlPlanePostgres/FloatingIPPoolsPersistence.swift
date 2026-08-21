import Foundation
import PostgresNIO
import StratoShared

public struct FloatingIPPoolSnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let cidr: String
    public let gateway: String?
    public let siteID: UUID
    public let organizationID: UUID?
    public let organizationalUnitID: UUID?
    public let allocatedCount: Int
    public let createdAt: Date?
    public let updatedAt: Date?
}

public struct FloatingIPPoolWrite: Sendable {
    public let id: UUID
    public let name: String
    public let cidr: String
    public let gateway: String?
    public let siteID: UUID
    public let organizationID: UUID?
    public let organizationalUnitID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        cidr: String,
        gateway: String?,
        siteID: UUID,
        organizationID: UUID?,
        organizationalUnitID: UUID?
    ) {
        self.id = id
        self.name = name
        self.cidr = cidr
        self.gateway = gateway
        self.siteID = siteID
        self.organizationID = organizationID
        self.organizationalUnitID = organizationalUnitID
    }
}

public enum FloatingIPPoolCreateResult: Equatable, Sendable {
    case created(FloatingIPPoolSnapshot)
    case siteNotFound
    case scopeNotFound
    case overlaps(name: String, cidr: String)
    case duplicateName
}

public enum FloatingIPPoolUpdateResult: Equatable, Sendable {
    case updated(FloatingIPPoolSnapshot)
    case notFound
    case siteNotFound
    case gatewayAlreadyAllocated
    case hasAttachedAddresses(Int)
    case overlaps(name: String, cidr: String)
}

public enum FloatingIPPoolDeleteResult: Equatable, Sendable {
    case deleted
    case notFound
    case hasAllocatedAddresses(Int)
}

public enum FloatingIPPoolsPersistenceError: Error, Equatable, Sendable {
    case invalidStoredCIDR(String)
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns external-address pool metadata and its overlap, gateway, and deletion
/// invariants. One transaction-scoped lock serializes the fleet-wide overlap
/// scan so concurrent pool creates cannot claim the same site address space.
public struct FloatingIPPoolsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func allPools() async throws -> [FloatingIPPoolSnapshot] {
        try await database.withSession(operation: "floating_ip_pools.list") { session in
            try await session.execute(
                ListFloatingIPPools(),
                operation: "floating_ip_pools.list.query"
            ).map(\.snapshot)
        }
    }

    public func pool(id: UUID) async throws -> FloatingIPPoolSnapshot? {
        try await database.withSession(operation: "floating_ip_pools.lookup") { session in
            let rows = try await session.execute(
                FindFloatingIPPool(id: id),
                operation: "floating_ip_pools.lookup.query"
            )
            guard rows.count <= 1 else {
                throw FloatingIPPoolsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return rows.first?.snapshot
        }
    }

    public func create(_ write: FloatingIPPoolWrite) async throws -> FloatingIPPoolCreateResult {
        do {
            return try await database.withTransaction(operation: "floating_ip_pools.create") { session in
                _ = try await session.execute(
                    LockFloatingIPPoolTopology(),
                    operation: "floating_ip_pools.create.lock"
                )
                guard try await exists(SiteExists(id: write.siteID), session: session) else {
                    return .siteNotFound
                }
                guard try await scopeExists(
                    organizationID: write.organizationID,
                    organizationalUnitID: write.organizationalUnitID,
                    session: session
                ) else {
                    return .scopeNotFound
                }
                if let overlap = try await overlap(
                    cidr: write.cidr,
                    siteID: write.siteID,
                    excluding: nil,
                    session: session
                ) {
                    return .overlaps(name: overlap.name, cidr: overlap.cidr)
                }
                let rows = try await session.execute(
                    InsertFloatingIPPool(write: write),
                    operation: "floating_ip_pools.create.insert"
                )
                guard rows.count == 1, let row = rows.first else {
                    throw FloatingIPPoolsPersistenceError.unexpectedRowCount(
                        expected: 1, actual: rows.count)
                }
                return .created(row.snapshot)
            }
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
            guard ["uq_floating_ip_pools_org_name", "uq_floating_ip_pools_ou_name"]
                .contains(error.serverInfo?[.constraintName])
            else { throw error }
            return .duplicateName
        }
    }

    public func update(id: UUID, gateway: String?, siteID: UUID) async throws
        -> FloatingIPPoolUpdateResult
    {
        try await database.withTransaction(operation: "floating_ip_pools.update") { session in
            _ = try await session.execute(
                LockFloatingIPPoolTopology(),
                operation: "floating_ip_pools.update.topology_lock"
            )
            let locked = try await session.execute(
                LockFloatingIPPool(id: id),
                operation: "floating_ip_pools.update.row_lock"
            )
            guard locked.count <= 1 else {
                throw FloatingIPPoolsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: locked.count)
            }
            guard let current = locked.first else { return .notFound }
            guard try await exists(SiteExists(id: siteID), session: session) else {
                return .siteNotFound
            }
            if let gateway {
                let collision = try await session.execute(
                    CountAllocatedAddress(poolID: id, address: gateway),
                    operation: "floating_ip_pools.update.gateway_collision"
                )
                if try only(collision) > 0 { return .gatewayAlreadyAllocated }
            }
            if siteID != current.siteID {
                let attached = try only(
                    await session.execute(
                        CountAttachedFloatingIPs(poolID: id),
                        operation: "floating_ip_pools.update.attachments"
                    )
                )
                if attached > 0 { return .hasAttachedAddresses(attached) }
                if let overlap = try await overlap(
                    cidr: current.cidr,
                    siteID: siteID,
                    excluding: id,
                    session: session
                ) {
                    return .overlaps(name: overlap.name, cidr: overlap.cidr)
                }
            }
            let rows = try await session.execute(
                UpdateFloatingIPPool(id: id, gateway: gateway, siteID: siteID),
                operation: "floating_ip_pools.update.query"
            )
            guard rows.count == 1, let row = rows.first else {
                throw FloatingIPPoolsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return .updated(row.snapshot)
        }
    }

    public func deleteIfEmpty(id: UUID) async throws -> FloatingIPPoolDeleteResult {
        try await database.withTransaction(operation: "floating_ip_pools.delete") { session in
            let locked = try await session.execute(
                LockFloatingIPPool(id: id),
                operation: "floating_ip_pools.delete.lock"
            )
            guard !locked.isEmpty else { return .notFound }
            let count = try only(
                await session.execute(
                    CountFloatingIPs(poolID: id),
                    operation: "floating_ip_pools.delete.allocations"
                )
            )
            if count > 0 { return .hasAllocatedAddresses(count) }
            let deleted = try await session.execute(
                DeleteFloatingIPPool(id: id),
                operation: "floating_ip_pools.delete.query"
            )
            guard deleted == [id] else {
                throw FloatingIPPoolsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: deleted.count)
            }
            return .deleted
        }
    }

    private func overlap(
        cidr: String,
        siteID: UUID,
        excluding id: UUID?,
        session: PostgresSession
    ) async throws -> FloatingIPPoolIdentity? {
        guard let requested = IPv4CIDR(cidr) else {
            throw FloatingIPPoolsPersistenceError.invalidStoredCIDR(cidr)
        }
        let rows = try await session.execute(
            ListFloatingIPPoolIdentities(siteID: siteID, excluding: id),
            operation: "floating_ip_pools.overlap.query"
        )
        for row in rows {
            guard let existing = IPv4CIDR(row.cidr) else {
                throw FloatingIPPoolsPersistenceError.invalidStoredCIDR(row.cidr)
            }
            if requested.overlaps(existing) { return row }
        }
        return nil
    }

    private func scopeExists(
        organizationID: UUID?,
        organizationalUnitID: UUID?,
        session: PostgresSession
    ) async throws -> Bool {
        switch (organizationID, organizationalUnitID) {
        case (.some(let id), .none):
            return try await exists(OrganizationExists(id: id), session: session)
        case (.none, .some(let id)):
            return try await exists(OrganizationalUnitExists(id: id), session: session)
        default:
            return false
        }
    }

    private func exists<S: PostgresPreparedStatement>(
        _ statement: S,
        session: PostgresSession
    ) async throws -> Bool where S.Row == Bool {
        try only(await session.execute(statement, operation: "floating_ip_pools.exists"))
    }
}

private func only<T>(_ values: [T]) throws -> T {
    guard values.count == 1, let value = values.first else {
        throw FloatingIPPoolsPersistenceError.unexpectedRowCount(
            expected: 1, actual: values.count)
    }
    return value
}

private struct FloatingIPPoolRecord: Sendable {
    let id: UUID
    let name: String
    let cidr: String
    let gateway: String?
    let siteID: UUID
    let organizationID: UUID?
    let organizationalUnitID: UUID?
    let allocatedCount: Int
    let createdAt: Date?
    let updatedAt: Date?

    init(row: PostgresRow) throws {
        (
            id, name, cidr, gateway, siteID, organizationID,
            organizationalUnitID, allocatedCount, createdAt, updatedAt
        ) = try row.decode((
            UUID, String, String, String?, UUID, UUID?, UUID?, Int, Date?, Date?
        ).self)
    }

    var snapshot: FloatingIPPoolSnapshot {
        FloatingIPPoolSnapshot(
            id: id,
            name: name,
            cidr: cidr,
            gateway: gateway,
            siteID: siteID,
            organizationID: organizationID,
            organizationalUnitID: organizationalUnitID,
            allocatedCount: allocatedCount,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private let floatingIPPoolColumns = """
    p.id, p.name, p.cidr, p.gateway, p.site_id,
    p.organization_id, p.organizational_unit_id,
    (SELECT count(*)::bigint FROM floating_ips WHERE pool_id = p.id),
    p.created_at, p.updated_at
    """

private protocol FloatingIPPoolStatement: PostgresPreparedStatement
    where Row == FloatingIPPoolRecord {}

private extension FloatingIPPoolStatement {
    func decodeRow(_ row: PostgresRow) throws -> FloatingIPPoolRecord {
        try FloatingIPPoolRecord(row: row)
    }
}

private struct ListFloatingIPPools: FloatingIPPoolStatement {
    static var sql: String {
        "SELECT \(floatingIPPoolColumns) FROM floating_ip_pools AS p ORDER BY p.name, p.id"
    }
    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct FindFloatingIPPool: FloatingIPPoolStatement {
    static var sql: String {
        "SELECT \(floatingIPPoolColumns) FROM floating_ip_pools AS p WHERE p.id = $1"
    }
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct LockFloatingIPPoolTopology: PostgresPreparedStatement {
    static let sql = "SELECT pg_advisory_xact_lock(hashtext('floating-ip-pools'))"
    typealias Row = Void
    func makeBindings() -> PostgresBindings { PostgresBindings() }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct BooleanExistsStatement: PostgresPreparedStatement {
    static let sql = "SELECT false"
    typealias Row = Bool
    func makeBindings() -> PostgresBindings { PostgresBindings() }
    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private protocol IDExistsStatement: PostgresPreparedStatement where Row == Bool {
    var id: UUID { get }
}

private extension IDExistsStatement {
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private struct SiteExists: IDExistsStatement {
    static let sql = "SELECT EXISTS(SELECT 1 FROM sites WHERE id = $1)"
    let id: UUID
}

private struct OrganizationExists: IDExistsStatement {
    static let sql = "SELECT EXISTS(SELECT 1 FROM organizations WHERE id = $1)"
    let id: UUID
}

private struct OrganizationalUnitExists: IDExistsStatement {
    static let sql = "SELECT EXISTS(SELECT 1 FROM organizational_units WHERE id = $1)"
    let id: UUID
}

private struct InsertFloatingIPPool: FloatingIPPoolStatement {
    static var sql: String {
        """
        WITH inserted AS (
            INSERT INTO floating_ip_pools (
                id, name, cidr, gateway, site_id, organization_id,
                organizational_unit_id, created_at, updated_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            RETURNING *
        )
        SELECT \(floatingIPPoolColumns) FROM inserted AS p
        """
    }
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .text, .text, .text, .uuid, .uuid, .uuid,
    ]
    let write: FloatingIPPoolWrite
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 7)
        bindings.append(write.id)
        bindings.append(write.name)
        bindings.append(write.cidr)
        bindings.append(write.gateway)
        bindings.append(write.siteID)
        bindings.append(write.organizationID)
        bindings.append(write.organizationalUnitID)
        return bindings
    }
}

private struct FloatingIPPoolIdentity: Sendable {
    let name: String
    let cidr: String
    let siteID: UUID
}

private struct ListFloatingIPPoolIdentities: PostgresPreparedStatement {
    static let sql = """
        SELECT name, cidr, site_id
        FROM floating_ip_pools
        WHERE site_id = $1 AND ($2::uuid IS NULL OR id <> $2)
        ORDER BY id
        """
    static let bindingDataTypes: [PostgresDataType] = [.uuid, .uuid]
    typealias Row = FloatingIPPoolIdentity
    let siteID: UUID
    let excluding: UUID?
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(siteID)
        bindings.append(excluding)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> FloatingIPPoolIdentity {
        let value = try row.decode((String, String, UUID).self)
        return FloatingIPPoolIdentity(name: value.0, cidr: value.1, siteID: value.2)
    }
}

private struct LockedFloatingIPPool: Sendable {
    let cidr: String
    let siteID: UUID
}

private struct LockFloatingIPPool: PostgresPreparedStatement {
    static let sql = "SELECT cidr, site_id FROM floating_ip_pools WHERE id = $1 FOR UPDATE"
    typealias Row = LockedFloatingIPPool
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> LockedFloatingIPPool {
        let value = try row.decode((String, UUID).self)
        return LockedFloatingIPPool(cidr: value.0, siteID: value.1)
    }
}

private protocol CountFloatingIPStatement: PostgresPreparedStatement where Row == Int {
    var poolID: UUID { get }
}

private extension CountFloatingIPStatement {
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(poolID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct CountFloatingIPs: CountFloatingIPStatement {
    static let sql = "SELECT count(*)::bigint FROM floating_ips WHERE pool_id = $1"
    let poolID: UUID
}

private struct CountAttachedFloatingIPs: CountFloatingIPStatement {
    static let sql = """
        SELECT count(*)::bigint FROM floating_ips
        WHERE pool_id = $1 AND (interface_id IS NOT NULL OR load_balancer_id IS NOT NULL)
        """
    let poolID: UUID
}

private struct CountAllocatedAddress: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM floating_ips WHERE pool_id = $1 AND address = $2"
    typealias Row = Int
    let poolID: UUID
    let address: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(poolID)
        bindings.append(address)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct UpdateFloatingIPPool: FloatingIPPoolStatement {
    static var sql: String {
        """
        WITH updated AS (
            UPDATE floating_ip_pools
            SET gateway = $2, site_id = $3, updated_at = CURRENT_TIMESTAMP
            WHERE id = $1
            RETURNING *
        )
        SELECT \(floatingIPPoolColumns) FROM updated AS p
        """
    }
    static let bindingDataTypes: [PostgresDataType] = [.uuid, .text, .uuid]
    let id: UUID
    let gateway: String?
    let siteID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(gateway)
        bindings.append(siteID)
        return bindings
    }
}

private struct DeleteFloatingIPPool: PostgresPreparedStatement {
    static let sql = "DELETE FROM floating_ip_pools WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}
