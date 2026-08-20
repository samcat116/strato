import Foundation
import PostgresNIO
import StratoShared

/// Immutable durable state returned after reserving one floating IPv4 address.
public struct FloatingIPAllocationSnapshot: Equatable, Sendable {
    public let id: UUID
    public let poolID: UUID
    public let address: String
    public let projectID: UUID
    public let interfaceID: UUID?
    public let loadBalancerID: UUID?
    public let vmID: UUID?
    public let fixedIP: String?
    public let networkID: UUID?
    public let networkName: String?
    public let createdByID: UUID?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: UUID,
        poolID: UUID,
        address: String,
        projectID: UUID,
        interfaceID: UUID? = nil,
        loadBalancerID: UUID? = nil,
        vmID: UUID? = nil,
        fixedIP: String? = nil,
        networkID: UUID? = nil,
        networkName: String? = nil,
        createdByID: UUID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.poolID = poolID
        self.address = address
        self.projectID = projectID
        self.interfaceID = interfaceID
        self.loadBalancerID = loadBalancerID
        self.vmID = vmID
        self.fixedIP = fixedIP
        self.networkID = networkID
        self.networkName = networkName
        self.createdByID = createdByID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum FloatingIPAllocationError: Error, Equatable, Sendable {
    case poolNotFound(UUID)
    case invalidSubnet(String)
    case invalidGateway(String)
    case poolExhausted(poolName: String, cidr: String)
    case unexpectedRowCount(expected: Int, actual: Int)
}

public enum FloatingIPReleaseResult: Equatable, Sendable {
    case released
    case notFound
    case attached
}

public enum FloatingIPAttachmentTarget: Equatable, Sendable {
    case interface(id: UUID, networkID: UUID)
    case loadBalancer(id: UUID, networkID: UUID)
}

public enum FloatingIPAttachmentResult: Equatable, Sendable {
    case attached(FloatingIPAllocationSnapshot)
    case unchanged(FloatingIPAllocationSnapshot)
    case notFound
    case alreadyAttached
    case targetInUse
    case networkNotFound
}

/// The exact NAT facts consumed by desired-state assembly. Keeping this value
/// in the persistence target prevents Fluent relationship objects from
/// escaping the query lease while preserving the batched assembly query.
public struct FloatingIPDesiredAttachmentSnapshot: Equatable, Sendable {
    public let externalIP: String
    public let logicalIP: String?
    public let networkID: UUID
    public let vmID: UUID?
    public let nicIndex: Int?

    public init(
        externalIP: String,
        logicalIP: String?,
        networkID: UUID,
        vmID: UUID? = nil,
        nicIndex: Int? = nil
    ) {
        self.externalIP = externalIP
        self.logicalIP = logicalIP
        self.networkID = networkID
        self.vmID = vmID
        self.nicIndex = nicIndex
    }
}

/// Owns the address-reservation invariant for floating IPs.
///
/// One native transaction takes a per-pool PostgreSQL advisory lock, reads the
/// committed used-address set, appends the allocation, and grants its creator
/// the seeded administrator role. No generic retry hides a failed transaction.
public struct FloatingIPAllocationsPersistence: Sendable {
    private static let adminRoleID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000004"
    )!

    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func allocate(
        fromPoolID poolID: UUID,
        toProjectID projectID: UUID,
        createdByID: UUID
    ) async throws -> FloatingIPAllocationSnapshot {
        try await database.withTransaction(operation: "floating_ips.allocate") { session in
            _ = try await session.execute(
                LockFloatingIPPoolAllocation(poolID: poolID),
                operation: "floating_ips.allocate.lock"
            )

            let poolRows = try await session.execute(
                LookupFloatingIPPoolForAllocation(id: poolID),
                operation: "floating_ips.allocate.pool"
            )
            guard poolRows.count <= 1 else {
                throw FloatingIPAllocationError.unexpectedRowCount(
                    expected: 1, actual: poolRows.count)
            }
            guard let pool = poolRows.first else {
                throw FloatingIPAllocationError.poolNotFound(poolID)
            }

            let used = try await session.execute(
                ListAllocatedFloatingIPAddresses(poolID: poolID),
                operation: "floating_ips.allocate.used"
            )
            let address = try Self.lowestFreeAddress(
                poolName: pool.name,
                cidr: pool.cidr,
                gateway: pool.gateway,
                usedAddresses: used
            )

            let allocationID = UUID()
            let rows = try await session.execute(
                InsertFloatingIPAllocation(
                    id: allocationID,
                    poolID: poolID,
                    address: address,
                    projectID: projectID,
                    createdByID: createdByID
                ),
                operation: "floating_ips.allocate.insert"
            )
            guard rows.count == 1, let allocation = rows.first else {
                throw FloatingIPAllocationError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }

            let bindingRows = try await session.execute(
                InsertFloatingIPCreatorBinding(
                    id: UUID(),
                    principalID: createdByID,
                    roleID: Self.adminRoleID,
                    nodeID: allocationID,
                    createdByID: createdByID
                ),
                operation: "floating_ips.allocate.grant_creator"
            )
            guard bindingRows.count == 1 else {
                throw FloatingIPAllocationError.unexpectedRowCount(
                    expected: 1, actual: bindingRows.count)
            }
            return allocation.snapshot
        }
    }

    public func allAllocations() async throws -> [FloatingIPAllocationSnapshot] {
        try await database.withSession(operation: "floating_ips.list") { session in
            try await session.execute(
                ListFloatingIPAllocations(),
                operation: "floating_ips.list.query"
            ).map(\.snapshot)
        }
    }

    public func allocations(projectIDs: [UUID]) async throws -> [FloatingIPAllocationSnapshot] {
        guard !projectIDs.isEmpty else { return [] }
        return try await database.withSession(operation: "floating_ips.list_scoped") { session in
            try await session.execute(
                ListProjectFloatingIPAllocations(projectIDs: Array(Set(projectIDs))),
                operation: "floating_ips.list_scoped.query"
            ).map(\.snapshot)
        }
    }

    public func allocation(id: UUID) async throws -> FloatingIPAllocationSnapshot? {
        try await database.withSession(operation: "floating_ips.lookup") { session in
            let rows = try await session.execute(
                FindFloatingIPAllocation(id: id),
                operation: "floating_ips.lookup.query"
            )
            guard rows.count <= 1 else {
                throw FloatingIPAllocationError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return rows.first?.snapshot
        }
    }

    public func allocations(ids: [UUID]) async throws -> [FloatingIPAllocationSnapshot] {
        guard !ids.isEmpty else { return [] }
        return try await database.withSession(operation: "floating_ips.lookup_many") { session in
            try await session.execute(
                FindFloatingIPAllocations(ids: Array(Set(ids))),
                operation: "floating_ips.lookup_many.query"
            ).map(\.snapshot)
        }
    }

    /// Attach an allocation and advance the affected network generation in
    /// one transaction. The row lock makes repeated requests idempotent; the
    /// partial unique indexes remain the authority under concurrent attaches.
    public func attach(
        id: UUID,
        to target: FloatingIPAttachmentTarget
    ) async throws -> FloatingIPAttachmentResult {
        do {
            return try await database.withTransaction(operation: "floating_ips.attach") { session in
                let rows = try await session.execute(
                    LockFloatingIPAllocation(id: id),
                    operation: "floating_ips.attach.lock"
                )
                guard rows.count <= 1 else {
                    throw FloatingIPAllocationError.unexpectedRowCount(
                        expected: 1, actual: rows.count)
                }
                guard let current = rows.first else { return .notFound }

                let targetID: UUID
                let networkID: UUID
                let sameTarget: Bool
                switch target {
                case .interface(let id, let targetNetworkID):
                    targetID = id
                    networkID = targetNetworkID
                    sameTarget = current.interfaceID == id && current.loadBalancerID == nil
                case .loadBalancer(let id, let targetNetworkID):
                    targetID = id
                    networkID = targetNetworkID
                    sameTarget = current.loadBalancerID == id && current.interfaceID == nil
                }

                if sameTarget {
                    return .unchanged(try await loadAllocation(id: id, session: session))
                }
                guard current.interfaceID == nil, current.loadBalancerID == nil else {
                    return .alreadyAttached
                }

                let updated: [UUID]
                switch target {
                case .interface:
                    updated = try await session.execute(
                        AttachFloatingIPToInterface(id: id, interfaceID: targetID),
                        operation: "floating_ips.attach.interface"
                    )
                case .loadBalancer:
                    updated = try await session.execute(
                        AttachFloatingIPToLoadBalancer(id: id, loadBalancerID: targetID),
                        operation: "floating_ips.attach.load_balancer"
                    )
                }
                guard updated == [id] else {
                    throw FloatingIPAllocationError.unexpectedRowCount(
                        expected: 1, actual: updated.count)
                }
                guard try await advanceNetworkGeneration(networkID, session: session) else {
                    throw FloatingIPAttachmentMutationError.networkNotFound
                }
                return .attached(try await loadAllocation(id: id, session: session))
            }
        } catch FloatingIPAttachmentMutationError.networkNotFound {
            return .networkNotFound
        } catch let error as PSQLError
            where error.serverInfo?[.sqlState] == "23505"
                && ["uq_floating_ips_interface", "uq_floating_ips_load_balancer_id"]
                    .contains(error.serverInfo?[.constraintName])
        {
            return .targetInUse
        }
    }

    /// Clear either attachment and advance the former network generation in
    /// the same transaction so desired state never observes a detached row
    /// without the corresponding convergence nonce.
    public func detach(id: UUID) async throws -> FloatingIPAttachmentResult {
        do {
            return try await database.withTransaction(operation: "floating_ips.detach") { session in
                let rows = try await session.execute(
                    LockFloatingIPAllocation(id: id),
                    operation: "floating_ips.detach.lock"
                )
                guard rows.count <= 1 else {
                    throw FloatingIPAllocationError.unexpectedRowCount(
                        expected: 1, actual: rows.count)
                }
                guard let current = rows.first else { return .notFound }
                guard current.interfaceID != nil || current.loadBalancerID != nil else {
                    return .unchanged(try await loadAllocation(id: id, session: session))
                }

                let updated = try await session.execute(
                    DetachFloatingIP(id: id),
                    operation: "floating_ips.detach.update"
                )
                guard updated == [id] else {
                    throw FloatingIPAllocationError.unexpectedRowCount(
                        expected: 1, actual: updated.count)
                }
                if let networkID = current.networkID,
                    try await advanceNetworkGeneration(networkID, session: session) == false
                {
                    throw FloatingIPAttachmentMutationError.networkNotFound
                }
                return .attached(try await loadAllocation(id: id, session: session))
            }
        } catch FloatingIPAttachmentMutationError.networkNotFound {
            return .networkNotFound
        }
    }

    public func attachedInterfaceCount(networkID: UUID) async throws -> Int {
        try await database.withSession(operation: "floating_ips.count_attached") { session in
            let rows = try await session.execute(
                CountNetworkFloatingIPAttachments(networkID: networkID),
                operation: "floating_ips.count_attached.query"
            )
            guard rows.count == 1, let count = rows.first else {
                throw FloatingIPAllocationError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return count
        }
    }

    public func desiredAttachments(
        forAgentIDs agentIDs: [String],
        networkIDs: [UUID]
    ) async throws -> [FloatingIPDesiredAttachmentSnapshot] {
        guard !agentIDs.isEmpty, !networkIDs.isEmpty else { return [] }
        return try await database.withSession(operation: "floating_ips.desired_state") { session in
            let vmRows = try await session.execute(
                ListDesiredVMFloatingIPs(
                    agentIDs: Array(Set(agentIDs)), networkIDs: Array(Set(networkIDs))),
                operation: "floating_ips.desired_state.vms"
            )
            let loadBalancerRows = try await session.execute(
                ListDesiredLoadBalancerFloatingIPs(networkIDs: Array(Set(networkIDs))),
                operation: "floating_ips.desired_state.load_balancers"
            )
            return vmRows + loadBalancerRows
        }
    }

    public func releaseIfDetached(id: UUID) async throws -> FloatingIPReleaseResult {
        try await database.withTransaction(operation: "floating_ips.release") { session in
            let rows = try await session.execute(
                LockFloatingIPAllocation(id: id),
                operation: "floating_ips.release.lock"
            )
            guard rows.count <= 1 else {
                throw FloatingIPAllocationError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            guard let attachment = rows.first else { return .notFound }
            guard attachment.interfaceID == nil, attachment.loadBalancerID == nil else {
                return .attached
            }
            _ = try await session.execute(
                DeleteFloatingIPBindings(nodeID: id),
                operation: "floating_ips.release.bindings"
            )
            let deleted = try await session.execute(
                DeleteFloatingIPAllocation(id: id),
                operation: "floating_ips.release.query"
            )
            guard deleted == [id] else {
                throw FloatingIPAllocationError.unexpectedRowCount(
                    expected: 1, actual: deleted.count)
            }
            return .released
        }
    }

    private func loadAllocation(
        id: UUID,
        session: PostgresSession
    ) async throws -> FloatingIPAllocationSnapshot {
        let rows = try await session.execute(
            FindFloatingIPAllocation(id: id),
            operation: "floating_ips.mutation.reload"
        )
        guard rows.count == 1, let allocation = rows.first else {
            throw FloatingIPAllocationError.unexpectedRowCount(
                expected: 1, actual: rows.count)
        }
        return allocation.snapshot
    }

    private func advanceNetworkGeneration(
        _ networkID: UUID,
        session: PostgresSession
    ) async throws -> Bool {
        let rows = try await session.execute(
            AdvanceFloatingIPNetworkGeneration(id: networkID),
            operation: "floating_ips.network_generation.advance"
        )
        guard rows.count <= 1 else {
            throw FloatingIPAllocationError.unexpectedRowCount(
                expected: 1, actual: rows.count)
        }
        return rows.count == 1
    }

    /// Pure allocation core retained here so the database transaction and the
    /// address-selection rule cannot drift apart.
    static func lowestFreeAddress(
        poolName: String,
        cidr: String,
        gateway: String?,
        usedAddresses: [String]
    ) throws -> String {
        guard let parsed = IPv4CIDR(cidr), (8...30).contains(parsed.prefix) else {
            throw FloatingIPAllocationError.invalidSubnet(cidr)
        }

        let mask: UInt32 = ~UInt32(0) << (32 - parsed.prefix)
        let networkAddress = parsed.base.raw & mask
        let broadcastAddress = networkAddress | ~mask
        let gatewayValue: UInt32?
        if let gateway {
            guard let parsedGateway = IPv4Address(gateway) else {
                throw FloatingIPAllocationError.invalidGateway(gateway)
            }
            gatewayValue = parsedGateway.raw
        } else {
            gatewayValue = nil
        }
        let used = Set(usedAddresses.compactMap { IPv4Address($0)?.raw })

        for candidate in (networkAddress + 1)..<broadcastAddress {
            if candidate == gatewayValue || used.contains(candidate) { continue }
            return IPv4Address(raw: candidate).description
        }
        throw FloatingIPAllocationError.poolExhausted(poolName: poolName, cidr: cidr)
    }
}

private enum FloatingIPAttachmentMutationError: Error {
    case networkNotFound
}

private struct FloatingIPPoolAllocationRecord: Sendable {
    let name: String
    let cidr: String
    let gateway: String?

    init(row: PostgresRow) throws {
        (name, cidr, gateway) = try row.decode((String, String, String?).self)
    }
}

private struct FloatingIPAllocationRecord: Sendable {
    let id: UUID
    let poolID: UUID
    let address: String
    let projectID: UUID
    let interfaceID: UUID?
    let loadBalancerID: UUID?
    let createdByID: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let vmID: UUID?
    let fixedIP: String?
    let networkID: UUID?
    let networkName: String?

    init(row: PostgresRow) throws {
        (
            id, poolID, address, projectID, interfaceID, loadBalancerID,
            createdByID, createdAt, updatedAt,
            vmID, fixedIP, networkID, networkName
        ) = try row.decode((
            UUID, UUID, String, UUID, UUID?, UUID?, UUID?, Date?, Date?,
            UUID?, String?, UUID?, String?
        ).self)
    }

    var snapshot: FloatingIPAllocationSnapshot {
        FloatingIPAllocationSnapshot(
            id: id,
            poolID: poolID,
            address: address,
            projectID: projectID,
            interfaceID: interfaceID,
            loadBalancerID: loadBalancerID,
            vmID: vmID,
            fixedIP: fixedIP,
            networkID: networkID,
            networkName: networkName,
            createdByID: createdByID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct LockFloatingIPPoolAllocation: PostgresPreparedStatement {
    static let sql = "SELECT pg_advisory_xact_lock(hashtext($1))"
    typealias Row = Void
    let poolID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append("fip:\(poolID.uuidString)")
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws {}
}

private struct LookupFloatingIPPoolForAllocation: PostgresPreparedStatement {
    static let sql = "SELECT name, cidr, gateway FROM floating_ip_pools WHERE id = $1"
    typealias Row = FloatingIPPoolAllocationRecord
    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> FloatingIPPoolAllocationRecord {
        try FloatingIPPoolAllocationRecord(row: row)
    }
}

private struct ListAllocatedFloatingIPAddresses: PostgresPreparedStatement {
    static let sql = "SELECT address FROM floating_ips WHERE pool_id = $1 ORDER BY address"
    typealias Row = String
    let poolID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(poolID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> String {
        try row.decode(String.self)
    }
}

private let floatingIPAllocationColumns = """
    f.id, f.pool_id, f.address, f.project_id, f.interface_id, f.load_balancer_id,
    f.created_by_id, f.created_at, f.updated_at,
    interface.vm_id, fixed.address,
    COALESCE(interface.logical_network_id, load_balancer.logical_network_id),
    network.name
    """

private let floatingIPAllocationFrom = """
    FROM floating_ips AS f
    LEFT JOIN vm_network_interfaces AS interface ON interface.id = f.interface_id
    LEFT JOIN vm_interface_addresses AS fixed
        ON fixed.interface_id = interface.id AND fixed.family = 'ipv4'
    LEFT JOIN load_balancers AS load_balancer ON load_balancer.id = f.load_balancer_id
    LEFT JOIN logical_networks AS network
        ON network.id = COALESCE(interface.logical_network_id, load_balancer.logical_network_id)
    """

private struct InsertFloatingIPAllocation: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO floating_ips AS f (
            id, pool_id, address, project_id, created_by_id, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, CURRENT_TIMESTAMP, NULL)
        RETURNING f.id, f.pool_id, f.address, f.project_id, f.interface_id,
                  f.load_balancer_id, f.created_by_id, f.created_at, f.updated_at,
                  NULL::uuid, NULL::text, NULL::uuid, NULL::text
        """
    typealias Row = FloatingIPAllocationRecord
    let id: UUID
    let poolID: UUID
    let address: String
    let projectID: UUID
    let createdByID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(poolID)
        bindings.append(address)
        bindings.append(projectID)
        bindings.append(createdByID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> FloatingIPAllocationRecord {
        try FloatingIPAllocationRecord(row: row)
    }
}

private protocol FloatingIPAllocationStatement: PostgresPreparedStatement
    where Row == FloatingIPAllocationRecord {}

private extension FloatingIPAllocationStatement {
    func decodeRow(_ row: PostgresRow) throws -> FloatingIPAllocationRecord {
        try FloatingIPAllocationRecord(row: row)
    }
}

private struct ListFloatingIPAllocations: FloatingIPAllocationStatement {
    static var sql: String {
        "SELECT \(floatingIPAllocationColumns) \(floatingIPAllocationFrom) ORDER BY f.created_at DESC, f.id DESC"
    }
    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct ListProjectFloatingIPAllocations: FloatingIPAllocationStatement {
    static var sql: String {
        """
        SELECT \(floatingIPAllocationColumns) \(floatingIPAllocationFrom)
        WHERE f.project_id = ANY($1::uuid[])
        ORDER BY f.created_at DESC, f.id DESC
        """
    }
    let projectIDs: [UUID]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(projectIDs)
        return bindings
    }
}

private struct FindFloatingIPAllocation: FloatingIPAllocationStatement {
    static var sql: String {
        "SELECT \(floatingIPAllocationColumns) \(floatingIPAllocationFrom) WHERE f.id = $1"
    }
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct FindFloatingIPAllocations: FloatingIPAllocationStatement {
    static var sql: String {
        "SELECT \(floatingIPAllocationColumns) \(floatingIPAllocationFrom) WHERE f.id = ANY($1::uuid[]) ORDER BY f.id"
    }
    let ids: [UUID]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(ids)
        return bindings
    }
}

private struct FloatingIPAttachment: Sendable {
    let interfaceID: UUID?
    let loadBalancerID: UUID?
    let networkID: UUID?
}

private struct LockFloatingIPAllocation: PostgresPreparedStatement {
    static let sql = """
        SELECT f.interface_id, f.load_balancer_id,
               COALESCE(interface.logical_network_id, load_balancer.logical_network_id)
        FROM floating_ips AS f
        LEFT JOIN vm_network_interfaces AS interface ON interface.id = f.interface_id
        LEFT JOIN load_balancers AS load_balancer ON load_balancer.id = f.load_balancer_id
        WHERE f.id = $1
        FOR UPDATE OF f
        """
    typealias Row = FloatingIPAttachment
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> FloatingIPAttachment {
        let value = try row.decode((UUID?, UUID?, UUID?).self)
        return FloatingIPAttachment(
            interfaceID: value.0, loadBalancerID: value.1, networkID: value.2)
    }
}

private protocol FloatingIPIdentifierStatement: PostgresPreparedStatement where Row == UUID {}

private extension FloatingIPIdentifierStatement {
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct AttachFloatingIPToInterface: FloatingIPIdentifierStatement {
    static let sql = """
        UPDATE floating_ips
        SET interface_id = $2, load_balancer_id = NULL, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id
        """
    let id: UUID
    let interfaceID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(interfaceID)
        return bindings
    }
}

private struct AttachFloatingIPToLoadBalancer: FloatingIPIdentifierStatement {
    static let sql = """
        UPDATE floating_ips
        SET interface_id = NULL, load_balancer_id = $2, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id
        """
    let id: UUID
    let loadBalancerID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(loadBalancerID)
        return bindings
    }
}

private struct DetachFloatingIP: FloatingIPIdentifierStatement {
    static let sql = """
        UPDATE floating_ips
        SET interface_id = NULL, load_balancer_id = NULL, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id
        """
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct AdvanceFloatingIPNetworkGeneration: PostgresPreparedStatement {
    static let sql = """
        UPDATE logical_networks
        SET generation = generation + 1
        WHERE id = $1
        RETURNING generation
        """
    typealias Row = Int64
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int64 { try row.decode(Int64.self) }
}

private struct CountNetworkFloatingIPAttachments: PostgresPreparedStatement {
    static let sql = """
        SELECT count(*)::bigint
        FROM floating_ips AS f
        JOIN vm_network_interfaces AS interface ON interface.id = f.interface_id
        WHERE interface.logical_network_id = $1
        """
    typealias Row = Int
    let networkID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(networkID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct FloatingIPDesiredAttachmentRecord: Sendable {
    let externalIP: String
    let logicalIP: String?
    let networkID: UUID
    let vmID: UUID?
    let nicIndex: Int?

    init(row: PostgresRow) throws {
        (externalIP, logicalIP, networkID, vmID, nicIndex) = try row.decode(
            (String, String?, UUID, UUID?, Int?).self)
    }

    var snapshot: FloatingIPDesiredAttachmentSnapshot {
        FloatingIPDesiredAttachmentSnapshot(
            externalIP: externalIP,
            logicalIP: logicalIP,
            networkID: networkID,
            vmID: vmID,
            nicIndex: nicIndex
        )
    }
}

private protocol FloatingIPDesiredAttachmentStatement: PostgresPreparedStatement
    where Row == FloatingIPDesiredAttachmentSnapshot {}

private extension FloatingIPDesiredAttachmentStatement {
    func decodeRow(_ row: PostgresRow) throws -> FloatingIPDesiredAttachmentSnapshot {
        try FloatingIPDesiredAttachmentRecord(row: row).snapshot
    }
}

private struct ListDesiredVMFloatingIPs: FloatingIPDesiredAttachmentStatement {
    static let sql = """
        SELECT f.address, fixed.address, interface.logical_network_id,
               interface.vm_id, interface.order_index
        FROM floating_ips AS f
        JOIN vm_network_interfaces AS interface ON interface.id = f.interface_id
        JOIN vms AS vm ON vm.id = interface.vm_id
        LEFT JOIN vm_interface_addresses AS fixed
            ON fixed.interface_id = interface.id AND fixed.family = 'ipv4'
        WHERE vm.hypervisor_id = ANY($1::text[])
          AND interface.logical_network_id = ANY($2::uuid[])
          AND interface.detach_generation IS NULL
        ORDER BY f.address, f.id
        """
    let agentIDs: [String]
    let networkIDs: [UUID]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(agentIDs)
        bindings.append(networkIDs)
        return bindings
    }
}

private struct ListDesiredLoadBalancerFloatingIPs: FloatingIPDesiredAttachmentStatement {
    static let sql = """
        SELECT f.address, load_balancer.vip, load_balancer.logical_network_id,
               NULL::uuid, NULL::integer
        FROM floating_ips AS f
        JOIN load_balancers AS load_balancer ON load_balancer.id = f.load_balancer_id
        WHERE load_balancer.logical_network_id = ANY($1::uuid[])
        ORDER BY f.address, f.id
        """
    let networkIDs: [UUID]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(networkIDs)
        return bindings
    }
}

private struct DeleteFloatingIPBindings: PostgresPreparedStatement {
    static let sql = "DELETE FROM role_bindings WHERE node_type = 'floating_ip' AND node_id = $1"
    typealias Row = Void
    let nodeID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(nodeID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct DeleteFloatingIPAllocation: PostgresPreparedStatement {
    static let sql = "DELETE FROM floating_ips WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertFloatingIPCreatorBinding: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO role_bindings (
            id, principal_type, principal_id, role_id, node_type, node_id,
            condition, expires_at, created_by, created_at
        ) VALUES ($1, 'user', $2, $3, 'floating_ip', $4, NULL, NULL, $5, CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let principalID: UUID
    let roleID: UUID
    let nodeID: UUID
    let createdByID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(principalID)
        bindings.append(roleID)
        bindings.append(nodeID)
        bindings.append(createdByID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.decode(UUID.self)
    }
}
