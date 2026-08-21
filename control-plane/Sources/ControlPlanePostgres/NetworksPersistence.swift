import Foundation
import PostgresNIO
import StratoShared

public struct NetworkSnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let subnet: String
    public let gateway: String?
    public let subnet6: String?
    public let gateway6: String?
    public let projectID: UUID
    public let createdByID: UUID?
    public let dhcpEnabled: Bool
    public let dnsServers: [String]
    public let domainName: String?
    public let leaseTime: Int?
    public let externalAccess: Bool
    public let metadataEnabled: Bool
    public let resolverEnabled: Bool
    public let resolverIndex: Int?
    public let generation: Int
    public let siteID: UUID
    public let primaryDNSZoneID: UUID?
    public let createdAt: Date?
    public let updatedAt: Date?
}

public struct NetworkOverview: Equatable, Sendable {
    public let network: NetworkSnapshot
    public let attachedInterfaceCount: Int
    public let attachedZoneCount: Int
    public let resolverIncapableAgentNames: [String]
}

public struct NetworkCreateWrite: Sendable {
    public let id: UUID
    public let name: String
    public let subnet: String
    public let gateway: String
    public let subnet6: String?
    public let gateway6: String?
    public let projectID: UUID
    public let creatorID: UUID
    public let administratorRoleID: UUID
    public let dhcpEnabled: Bool
    public let dnsServers: [String]
    public let domainName: String?
    public let leaseTime: Int?
    public let externalAccess: Bool
    public let metadataEnabled: Bool
    public let resolverEnabled: Bool
    public let siteID: UUID

    public init(
        id: UUID = UUID(),
        name: String,
        subnet: String,
        gateway: String,
        subnet6: String?,
        gateway6: String?,
        projectID: UUID,
        creatorID: UUID,
        administratorRoleID: UUID,
        dhcpEnabled: Bool,
        dnsServers: [String],
        domainName: String?,
        leaseTime: Int?,
        externalAccess: Bool,
        metadataEnabled: Bool,
        resolverEnabled: Bool,
        siteID: UUID
    ) {
        self.id = id
        self.name = name
        self.subnet = subnet
        self.gateway = gateway
        self.subnet6 = subnet6
        self.gateway6 = gateway6
        self.projectID = projectID
        self.creatorID = creatorID
        self.administratorRoleID = administratorRoleID
        self.dhcpEnabled = dhcpEnabled
        self.dnsServers = dnsServers
        self.domainName = domainName
        self.leaseTime = leaseTime
        self.externalAccess = externalAccess
        self.metadataEnabled = metadataEnabled
        self.resolverEnabled = resolverEnabled
        self.siteID = siteID
    }
}

public enum NetworkCreateResult: Equatable, Sendable {
    case created(NetworkOverview)
    case projectNotFound
    case siteNotFound
    case duplicateName
    case quotaExceeded(name: String, limit: Int)
    case resolverAddressExhausted(capacity: Int)
}

public enum NetworkDeleteResult: Equatable, Sendable {
    case deleted(NetworkSnapshot)
    case notFound
    case hasInterfaces(Int)
    case hasLoadBalancers(Int)
}

public enum NetworksPersistenceError: Error, Equatable, Sendable {
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Native read model for logical networks. Counts are produced with one query
/// for the page, and resolver capability is loaded once for only the sites
/// whose networks actually have attached DNS zones.
public struct NetworksPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func allNetworks() async throws -> [NetworkOverview] {
        try await database.withSession(operation: "networks.list") { session in
            let rows = try await session.execute(
                ListNetworks(),
                operation: "networks.list.query"
            )
            return try await addResolverCapability(to: rows, session: session)
        }
    }

    public func networks(projectIDs: [UUID]) async throws -> [NetworkOverview] {
        guard !projectIDs.isEmpty else { return [] }
        return try await database.withSession(operation: "networks.list_scoped") { session in
            let rows = try await session.execute(
                ListProjectNetworks(projectIDs: Array(Set(projectIDs))),
                operation: "networks.list_scoped.query"
            )
            return try await addResolverCapability(to: rows, session: session)
        }
    }

    public func network(id: UUID) async throws -> NetworkOverview? {
        try await database.withSession(operation: "networks.lookup") { session in
            let rows = try await session.execute(
                FindNetwork(id: id),
                operation: "networks.lookup.query"
            )
            guard rows.count <= 1 else {
                throw NetworksPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
            }
            return try await addResolverCapability(to: rows, session: session).first
        }
    }

    /// Inserts a logical network, reserves every applicable project-wide
    /// quota, allocates a fleet-wide resolver address, and grants the creator
    /// its admin binding in one transaction.
    public func create(_ write: NetworkCreateWrite) async throws -> NetworkCreateResult {
        do {
            return try await database.withTransaction(operation: "networks.create") { session in
                _ = try await session.execute(
                    LockNetworkProjectMutations(id: write.projectID),
                    operation: "networks.create.project_advisory_lock"
                )
                let projects = try await session.execute(
                    FindNetworkProjectForUpdate(id: write.projectID),
                    operation: "networks.create.project"
                )
                guard projects.count <= 1 else {
                    throw NetworksPersistenceError.unexpectedRowCount(
                        expected: 1,
                        actual: projects.count
                    )
                }
                guard let project = projects.first else { return .projectNotFound }

                let siteExists = try await session.execute(
                    NetworkSiteExists(id: write.siteID),
                    operation: "networks.create.site"
                )
                guard siteExists == [true] else { return .siteNotFound }

                let ancestorIDs: [UUID]
                if let organizationalUnitID = project.organizationalUnitID {
                    ancestorIDs = try await session.execute(
                        FindNetworkProjectOrganizationalUnitAncestors(id: organizationalUnitID),
                        operation: "networks.create.folder_ancestors"
                    )
                } else {
                    ancestorIDs = []
                }
                let quotas = try await session.execute(
                    FindNetworkProjectWideQuotas(
                        projectID: write.projectID,
                        organizationID: project.rootOrganizationID,
                        organizationalUnitIDs: ancestorIDs
                    ),
                    operation: "networks.create.quotas"
                )
                for quota in quotas {
                    _ = try await session.execute(
                        LockNetworkQuota(id: quota.id),
                        operation: "networks.create.quota_advisory_lock"
                    )
                    let measured = try await measure(quota, session: session)
                    let (nextCount, overflow) = measured.networkCount.addingReportingOverflow(1)
                    if quota.isEnabled && (overflow || nextCount > quota.maxNetworks) {
                        return .quotaExceeded(name: quota.name, limit: quota.maxNetworks)
                    }
                    _ = try await session.execute(
                        UpdateNetworkQuotaReservation(
                            id: quota.id,
                            usage: measured,
                            networkCount: nextCount
                        ),
                        operation: "networks.create.quota_reservation"
                    )
                }

                var resolverIndex: Int?
                if write.resolverEnabled {
                    _ = try await session.execute(
                        LockResolverIndexAllocation(),
                        operation: "networks.create.resolver_lock"
                    )
                    let used = Set(
                        try await session.execute(
                            ListAllocatedResolverIndexes(),
                            operation: "networks.create.resolver_indexes"
                        )
                    )
                    guard let index = firstFreeResolverIndex(used: used) else {
                        return .resolverAddressExhausted(
                            capacity: NetworkResolverEndpoint.lastIndex
                                - NetworkResolverEndpoint.firstIndex + 1
                        )
                    }
                    resolverIndex = index
                }

                let inserted = try await session.execute(
                    InsertNetwork(write: write, resolverIndex: resolverIndex),
                    operation: "networks.create.insert"
                )
                guard inserted.count == 1, let record = inserted.first else {
                    throw NetworksPersistenceError.unexpectedRowCount(
                        expected: 1,
                        actual: inserted.count
                    )
                }
                _ = try await session.execute(
                    InsertNetworkCreatorBinding(
                        id: UUID(),
                        creatorID: write.creatorID,
                        roleID: write.administratorRoleID,
                        networkID: write.id
                    ),
                    operation: "networks.create.binding"
                )
                return .created(
                    NetworkOverview(
                        network: record.snapshot,
                        attachedInterfaceCount: 0,
                        attachedZoneCount: 0,
                        resolverIncapableAgentNames: []
                    )
                )
            }
        } catch let error as PSQLError
            where error.serverInfo?[.sqlState] == "23505"
                && error.serverInfo?[.constraintName]
                    == "uq:logical_networks.project_id+logical_networks.name"
        {
            return .duplicateName
        }
    }

    public func deleteIfUnused(id: UUID) async throws -> NetworkDeleteResult {
        try await database.withTransaction(operation: "networks.delete") { session in
            let projectIDs = try await session.execute(
                FindNetworkProjectID(id: id),
                operation: "networks.delete.project"
            )
            guard projectIDs.count <= 1 else {
                throw NetworksPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: projectIDs.count
                )
            }
            guard let projectID = projectIDs.first else { return .notFound }
            _ = try await session.execute(
                LockNetworkProjectMutations(id: projectID),
                operation: "networks.delete.project_advisory_lock"
            )

            let rows = try await session.execute(
                LockNetwork(id: id),
                operation: "networks.delete.lock"
            )
            guard rows.count <= 1 else {
                throw NetworksPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: rows.count
                )
            }
            guard let record = rows.first else { return .notFound }
            if record.attachedInterfaceCount > 0 {
                return .hasInterfaces(record.attachedInterfaceCount)
            }
            let loadBalancerCounts = try await session.execute(
                CountNetworkLoadBalancers(id: id),
                operation: "networks.delete.load_balancers"
            )
            guard loadBalancerCounts.count == 1, let loadBalancerCount = loadBalancerCounts.first else {
                throw NetworksPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: loadBalancerCounts.count
                )
            }
            if loadBalancerCount > 0 { return .hasLoadBalancers(loadBalancerCount) }

            let projects = try await session.execute(
                FindNetworkProjectForUpdate(id: projectID),
                operation: "networks.delete.project_scope"
            )
            guard projects.count == 1, let project = projects.first else {
                // The network FK is cascading, so a concurrently deleted
                // project means the network is already disappearing too.
                return .notFound
            }
            let ancestorIDs: [UUID]
            if let organizationalUnitID = project.organizationalUnitID {
                ancestorIDs = try await session.execute(
                    FindNetworkProjectOrganizationalUnitAncestors(id: organizationalUnitID),
                    operation: "networks.delete.folder_ancestors"
                )
            } else {
                ancestorIDs = []
            }
            let quotas = try await session.execute(
                FindNetworkProjectWideQuotas(
                    projectID: projectID,
                    organizationID: project.rootOrganizationID,
                    organizationalUnitIDs: ancestorIDs
                ),
                operation: "networks.delete.quotas"
            )
            for quota in quotas {
                _ = try await session.execute(
                    LockNetworkQuota(id: quota.id),
                    operation: "networks.delete.quota_advisory_lock"
                )
            }

            let deleted = try await session.execute(
                DeleteNetwork(id: id),
                operation: "networks.delete.row"
            )
            guard deleted == [id] else {
                throw NetworksPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: deleted.count
                )
            }
            _ = try await session.execute(
                DeleteNetworkBindings(id: id),
                operation: "networks.delete.bindings"
            )
            for quota in quotas {
                let usage = try await measure(quota, session: session)
                _ = try await session.execute(
                    UpdateNetworkQuotaReservation(
                        id: quota.id,
                        usage: usage,
                        networkCount: usage.networkCount
                    ),
                    operation: "networks.delete.quota_resync"
                )
            }
            return .deleted(record.snapshot)
        }
    }

    private func measure(
        _ quota: ResourceQuotaSnapshot,
        session: PostgresSession
    ) async throws -> ResourceQuotaMeasuredUsage {
        let rows = try await session.execute(
            MeasureResourceQuotaScope(scope: .init(quota)),
            operation: "networks.create.measure_quota"
        )
        guard rows.count == 1, let usage = rows.first else {
            throw NetworksPersistenceError.unexpectedRowCount(
                expected: 1,
                actual: rows.count
            )
        }
        return usage
    }

    private func firstFreeResolverIndex(used: Set<Int>) -> Int? {
        var candidate = NetworkResolverEndpoint.firstIndex
        while candidate <= NetworkResolverEndpoint.lastIndex {
            if NetworkResolverEndpoint.isValidIndex(candidate), !used.contains(candidate) {
                return candidate
            }
            candidate += 1
        }
        return nil
    }

    private func addResolverCapability(
        to rows: [NetworkRecord],
        session: PostgresSession
    ) async throws -> [NetworkOverview] {
        let relevantSiteIDs = Array(Set(rows.filter { $0.attachedZoneCount > 0 }.map(\.siteID)))
        let incapable: [ResolverIncapableAgent]
        if relevantSiteIDs.isEmpty {
            incapable = []
        } else {
            incapable = try await session.execute(
                ListResolverIncapableAgents(siteIDs: relevantSiteIDs),
                operation: "networks.resolver_capability.query"
            ).compactMap { $0 }
        }
        let bySite = Dictionary(grouping: incapable, by: \.siteID)
            .mapValues { $0.map(\.name).sorted() }
        return rows.map {
            NetworkOverview(
                network: $0.snapshot,
                attachedInterfaceCount: $0.attachedInterfaceCount,
                attachedZoneCount: $0.attachedZoneCount,
                resolverIncapableAgentNames: bySite[$0.siteID] ?? []
            )
        }
    }
}

private struct NetworkRecord: Sendable {
    let id: UUID
    let name: String
    let subnet: String
    let gateway: String?
    let subnet6: String?
    let gateway6: String?
    let projectID: UUID
    let createdByID: UUID?
    let dhcpEnabled: Bool
    let dnsServersRaw: String?
    let domainName: String?
    let leaseTime: Int?
    let externalAccess: Bool
    let metadataEnabled: Bool
    let resolverEnabled: Bool
    let resolverIndex: Int?
    let generation: Int
    let siteID: UUID
    let primaryDNSZoneID: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let attachedInterfaceCount: Int
    let attachedZoneCount: Int

    init(row: PostgresRow) throws {
        let value = try row.decode((
            UUID, String, String, String?, String?, String?, UUID, UUID?, Bool, String?,
            String?, Int?, Bool, Bool, Bool, Int?, Int, UUID, UUID?, Date?, Date?, Int, Int
        ).self)
        id = value.0
        name = value.1
        subnet = value.2
        gateway = value.3
        subnet6 = value.4
        gateway6 = value.5
        projectID = value.6
        createdByID = value.7
        dhcpEnabled = value.8
        dnsServersRaw = value.9
        domainName = value.10
        leaseTime = value.11
        externalAccess = value.12
        metadataEnabled = value.13
        resolverEnabled = value.14
        resolverIndex = value.15
        generation = value.16
        siteID = value.17
        primaryDNSZoneID = value.18
        createdAt = value.19
        updatedAt = value.20
        attachedInterfaceCount = value.21
        attachedZoneCount = value.22
    }

    var snapshot: NetworkSnapshot {
        NetworkSnapshot(
            id: id,
            name: name,
            subnet: subnet,
            gateway: gateway,
            subnet6: subnet6,
            gateway6: gateway6,
            projectID: projectID,
            createdByID: createdByID,
            dhcpEnabled: dhcpEnabled,
            dnsServers: dnsServersRaw.map {
                $0.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } ?? [],
            domainName: domainName,
            leaseTime: leaseTime,
            externalAccess: externalAccess,
            metadataEnabled: metadataEnabled,
            resolverEnabled: resolverEnabled,
            resolverIndex: resolverIndex,
            generation: generation,
            siteID: siteID,
            primaryDNSZoneID: primaryDNSZoneID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private let networkColumns = """
    n.id, n.name, n.subnet, n.gateway, n.subnet6, n.gateway6,
    n.project_id, n.created_by_id, n.dhcp_enabled, n.dns_servers,
    n.domain_name, n.lease_time, n.external_access, n.metadata_enabled,
    n.resolver_enabled, n.resolver_index, n.generation, n.site_id,
    n.primary_dns_zone_id, n.created_at, n.updated_at,
    (
        (SELECT count(*) FROM vm_network_interfaces WHERE logical_network_id = n.id)
        +
        (SELECT count(*) FROM sandbox_network_interfaces WHERE logical_network_id = n.id)
    )::bigint AS attached_interface_count,
    (SELECT count(*)::bigint FROM dns_zone_networks WHERE logical_network_id = n.id)
        AS attached_zone_count
    """

private protocol NetworkStatement: PostgresPreparedStatement where Row == NetworkRecord {}

private extension NetworkStatement {
    func decodeRow(_ row: PostgresRow) throws -> NetworkRecord { try NetworkRecord(row: row) }
}

private struct ListNetworks: NetworkStatement {
    static var sql: String {
        "SELECT \(networkColumns) FROM logical_networks AS n ORDER BY n.created_at DESC, n.id DESC"
    }
    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct ListProjectNetworks: NetworkStatement {
    static var sql: String {
        """
        SELECT \(networkColumns)
        FROM logical_networks AS n
        WHERE n.project_id = ANY($1::uuid[])
        ORDER BY n.created_at DESC, n.id DESC
        """
    }
    let projectIDs: [UUID]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(projectIDs)
        return bindings
    }
}

private struct FindNetwork: NetworkStatement {
    static var sql: String {
        "SELECT \(networkColumns) FROM logical_networks AS n WHERE n.id = $1"
    }
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct FindNetworkProjectID: PostgresPreparedStatement {
    static let sql = "SELECT project_id FROM logical_networks WHERE id = $1"
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct LockNetwork: NetworkStatement {
    static var sql: String {
        """
        SELECT \(networkColumns)
        FROM logical_networks AS n
        WHERE n.id = $1
        FOR UPDATE OF n
        """
    }
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct CountNetworkLoadBalancers: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM load_balancers WHERE logical_network_id = $1"
    typealias Row = Int
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct DeleteNetwork: PostgresPreparedStatement {
    static let sql = "DELETE FROM logical_networks WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteNetworkBindings: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM role_bindings WHERE node_type = 'network' AND node_id = $1
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct NetworkProjectScope: Sendable {
    let organizationalUnitID: UUID?
    let rootOrganizationID: UUID?
}

private struct FindNetworkProjectForUpdate: PostgresPreparedStatement {
    static let sql = """
        SELECT p.organizational_unit_id,
               COALESCE(p.organization_id, ou.organization_id)
        FROM projects AS p
        LEFT JOIN organizational_units AS ou ON ou.id = p.organizational_unit_id
        WHERE p.id = $1
        FOR UPDATE OF p
        """
    typealias Row = NetworkProjectScope
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> NetworkProjectScope {
        let value = try row.decode((UUID?, UUID?).self)
        return NetworkProjectScope(
            organizationalUnitID: value.0,
            rootOrganizationID: value.1
        )
    }
}

private struct NetworkSiteExists: PostgresPreparedStatement {
    static let sql = "SELECT EXISTS (SELECT 1 FROM sites WHERE id = $1)"
    typealias Row = Bool
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private struct FindNetworkProjectOrganizationalUnitAncestors: PostgresPreparedStatement {
    static let sql = """
        SELECT ancestor.id
        FROM organizational_units AS root
        JOIN organizational_units AS ancestor
          ON root.path = ancestor.path OR root.path LIKE ancestor.path || '/%'
        WHERE root.id = $1
        ORDER BY ancestor.depth, ancestor.id
        """
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct FindNetworkProjectWideQuotas: ResourceQuotaStatement {
    static let sql = """
        SELECT \(resourceQuotaColumns)
        FROM resource_quotas
        WHERE environment IS NULL AND (
            project_id = $1
            OR ($2::uuid IS NOT NULL AND organization_id = $2)
            OR organizational_unit_id = ANY($3::uuid[])
        )
        ORDER BY id
        """
    let projectID: UUID
    let organizationID: UUID?
    let organizationalUnitIDs: [UUID]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(projectID)
        bindings.append(organizationID)
        bindings.append(organizationalUnitIDs)
        return bindings
    }
}

private struct LockNetworkProjectMutations: PostgresPreparedStatement {
    static let sql = "SELECT pg_advisory_xact_lock(hashtext($1))"
    typealias Row = Void
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append("project-network:\(id.uuidString)")
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct LockNetworkQuota: PostgresPreparedStatement {
    static let sql = "SELECT pg_advisory_xact_lock(hashtext($1))"
    typealias Row = Void
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id.uuidString)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct UpdateNetworkQuotaReservation: PostgresPreparedStatement {
    static let sql = """
        UPDATE resource_quotas SET
            reserved_vcpus = $2, reserved_memory = $3, reserved_storage = $4,
            vm_count = $5, sandbox_count = $6, volume_count = $7,
            network_count = $8, load_balancer_count = $9,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let usage: ResourceQuotaMeasuredUsage
    let networkCount: Int
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 9)
        bindings.append(id)
        bindings.append(usage.vcpus)
        bindings.append(usage.memoryBytes)
        bindings.append(usage.storageBytes)
        bindings.append(usage.vmCount)
        bindings.append(usage.sandboxCount)
        bindings.append(usage.volumeCount)
        bindings.append(networkCount)
        bindings.append(usage.loadBalancerCount)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct LockResolverIndexAllocation: PostgresPreparedStatement {
    static let sql = "SELECT pg_advisory_xact_lock(hashtext('resolver-index'))"
    typealias Row = Void
    func makeBindings() -> PostgresBindings { PostgresBindings() }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct ListAllocatedResolverIndexes: PostgresPreparedStatement {
    static let sql = """
        SELECT resolver_index FROM logical_networks
        WHERE resolver_index IS NOT NULL ORDER BY resolver_index
        """
    typealias Row = Int
    func makeBindings() -> PostgresBindings { PostgresBindings() }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct InsertNetwork: NetworkStatement {
    static var sql: String {
        """
        WITH inserted AS (
            INSERT INTO logical_networks (
                id, name, subnet, gateway, subnet6, gateway6,
                project_id, created_by_id, dhcp_enabled, dns_servers,
                domain_name, lease_time, external_access, metadata_enabled,
                resolver_enabled, resolver_index, generation, site_id,
                primary_dns_zone_id, created_at, updated_at
            ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
                $11, $12, $13, $14, $15, $16, 1, $17, NULL,
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING *
        )
        SELECT \(networkColumns.replacingOccurrences(of: "n.", with: "inserted."))
        FROM inserted
        """
    }
    let write: NetworkCreateWrite
    let resolverIndex: Int?
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 17)
        bindings.append(write.id)
        bindings.append(write.name)
        bindings.append(write.subnet)
        bindings.append(write.gateway)
        bindings.append(write.subnet6)
        bindings.append(write.gateway6)
        bindings.append(write.projectID)
        bindings.append(write.creatorID)
        bindings.append(write.dhcpEnabled)
        bindings.append(write.dnsServers.isEmpty ? nil : write.dnsServers.joined(separator: ","))
        bindings.append(write.domainName)
        bindings.append(write.leaseTime)
        bindings.append(write.externalAccess)
        bindings.append(write.metadataEnabled)
        bindings.append(write.resolverEnabled)
        bindings.append(resolverIndex)
        bindings.append(write.siteID)
        return bindings
    }
}

private struct InsertNetworkCreatorBinding: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO role_bindings (
            id, principal_type, principal_id, role_id, node_type, node_id,
            condition, expires_at, created_by, created_at
        ) VALUES ($1, 'user', $2, $3, 'network', $4, NULL, NULL, $2, CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let creatorID: UUID
    let roleID: UUID
    let networkID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(id)
        bindings.append(creatorID)
        bindings.append(roleID)
        bindings.append(networkID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct ResolverIncapableAgent: Sendable {
    let siteID: UUID
    let name: String
}

private struct ResolverDependencyJSON: Codable, PostgresDecodable,
    PostgresArrayDecodable, Sendable
{
    static let psqlArrayType: PostgresDataType = .jsonbArray
    let value: NodeDependencyObservation

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(NodeDependencyObservation.self)
    }
}

private struct ListResolverIncapableAgents: PostgresPreparedStatement {
    static let sql = """
        SELECT site_id, name, resolver_capable,
               dependency_observations, dependency_observations_received_at
        FROM agents
        WHERE site_id = ANY($1::uuid[])
        ORDER BY site_id, name
        """
    typealias Row = ResolverIncapableAgent?
    let siteIDs: [UUID]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(siteIDs)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> ResolverIncapableAgent? {
        let value = try row.decode(
            (UUID, String, Bool, [ResolverDependencyJSON], Date?).self
        )
        let relevant = value.3.map(\.value).filter {
            $0.affectedCapabilities.contains(.networkResolver)
        }
        let dependenciesAllow: Bool
        if !relevant.isEmpty, let receivedAt = value.4 {
            dependenciesAllow = relevant.allSatisfy {
                $0.allowsNewWork(receivedAt: receivedAt, at: Date(), staleAfter: 60)
            }
        } else {
            dependenciesAllow = false
        }
        guard !(value.2 && dependenciesAllow) else { return nil }
        return ResolverIncapableAgent(siteID: value.0, name: value.1)
    }
}
