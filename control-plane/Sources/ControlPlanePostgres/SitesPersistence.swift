import Foundation
import PostgresNIO
import StratoShared

public struct SiteWrite: Sendable {
    public let id: UUID
    public let name: String
    public let description: String?
    public let status: String
    public let latitude: Double?
    public let longitude: Double?
    public let locationLabel: String?
    public let regionCode: String?
    public let labels: [String: String]
    public let organizationID: UUID?
    public let organizationalUnitID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        description: String?,
        status: String,
        latitude: Double?,
        longitude: Double?,
        locationLabel: String?,
        regionCode: String?,
        labels: [String: String],
        organizationID: UUID?,
        organizationalUnitID: UUID?
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.status = status
        self.latitude = latitude
        self.longitude = longitude
        self.locationLabel = locationLabel
        self.regionCode = regionCode
        self.labels = labels
        self.organizationID = organizationID
        self.organizationalUnitID = organizationalUnitID
    }
}

public struct SiteUpdate: Sendable {
    public let description: String?
    public let networkControllerAgentID: UUID?
    public let status: String?
    public let latitude: Double?
    public let longitude: Double?
    public let locationLabel: String?
    public let regionCode: String?
    public let labels: [String: String]

    public init(
        description: String?,
        networkControllerAgentID: UUID?,
        status: String?,
        latitude: Double?,
        longitude: Double?,
        locationLabel: String?,
        regionCode: String?,
        labels: [String: String]
    ) {
        self.description = description
        self.networkControllerAgentID = networkControllerAgentID
        self.status = status
        self.latitude = latitude
        self.longitude = longitude
        self.locationLabel = locationLabel
        self.regionCode = regionCode
        self.labels = labels
    }
}

public struct SiteControllerSnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let status: String
    public let lastHeartbeat: Date?
    public let supportsInterVMNetworking: Bool
}

public struct SiteSnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String?
    public let status: String
    public let latitude: Double?
    public let longitude: Double?
    public let locationLabel: String?
    public let regionCode: String?
    public let labels: [String: String]
    public let networkControllerAgentID: UUID?
    public let controller: SiteControllerSnapshot?
    public let organizationID: UUID?
    public let organizationalUnitID: UUID?
    public let createdAt: Date?
    public let updatedAt: Date?
}

public enum SiteCreateResult: Equatable, Sendable {
    case created(SiteSnapshot)
    case scopeNotFound
    case duplicateName
}

public enum SiteUpdateResult: Equatable, Sendable {
    case updated(SiteSnapshot)
    case notFound
    case controllerNotFound(UUID)
    case controllerOutsideSite(name: String)
    case controllerCannotAuthor(name: String)
}

public enum SiteDeleteResult: Equatable, Sendable {
    case deleted
    case notFound
    case hasAgents(Int)
    case hasNetworks(Int)
    case hasFloatingIPPools(Int)
}

public enum SiteAgentAssignmentResult: Sendable {
    case assigned(agent: AgentSnapshot, newlyDesignatedSiteName: String?)
    case siteNotFound
    case agentNotFound
    case outsideScope
    case controlsAnotherSite
    case hostsVirtualMachines(Int)
    case hostsSandboxes(Int)
}

public enum SitesPersistenceError: Error, Equatable, Sendable {
    case invalidLabels
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns site metadata and the invariants around topology authority.
///
/// A site update locks the row while validating its proposed controller. A
/// delete locks the row and refuses to change scope implicitly while agents,
/// networks, or floating-IP pools still reference it.
public struct SitesPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func allSites() async throws -> [SiteSnapshot] {
        try await database.withSession(operation: "sites.list") { session in
            try await session.execute(ListSites(), operation: "sites.list.query").map(\.snapshot)
        }
    }

    public func sites(organizationID: UUID, organizationalUnitIDs: [UUID]) async throws
        -> [SiteSnapshot]
    {
        try await database.withSession(operation: "sites.list_scoped") { session in
            try await session.execute(
                ListScopedSites(
                    organizationID: organizationID,
                    organizationalUnitIDs: organizationalUnitIDs
                ),
                operation: "sites.list_scoped.query"
            ).map(\.snapshot)
        }
    }

    public func site(id: UUID) async throws -> SiteSnapshot? {
        try await database.withSession(operation: "sites.lookup") { session in
            let rows = try await session.execute(FindSite(id: id), operation: "sites.lookup.query")
            guard rows.count <= 1 else {
                throw SitesPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
            }
            return rows.first?.snapshot
        }
    }

    public func agentCount(siteID: UUID) async throws -> Int {
        try await database.withSession(operation: "sites.agent_count") { session in
            let rows = try await session.execute(
                CountSiteAgents(id: siteID),
                operation: "sites.agent_count.query"
            )
            guard rows.count == 1, let count = rows.first else {
                throw SitesPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: rows.count
                )
            }
            return count
        }
    }

    public func create(_ write: SiteWrite) async throws -> SiteCreateResult {
        do {
            return try await database.withSession(operation: "sites.create") { session in
                let rows = try await session.execute(
                    InsertSite(write: write),
                    operation: "sites.create.query"
                )
                guard rows.count <= 1 else {
                    throw SitesPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
                }
                guard let row = rows.first else { return .scopeNotFound }
                return .created(row.snapshot)
            }
        } catch let error as PSQLError
            where error.serverInfo?[.sqlState] == "23505"
                && error.serverInfo?[.constraintName] == "uq:sites.name"
        {
            return .duplicateName
        }
    }

    public func update(id: UUID, with update: SiteUpdate) async throws -> SiteUpdateResult {
        try await database.withTransaction(operation: "sites.update") { session in
            let locked = try await session.execute(
                LockSite(id: id),
                operation: "sites.update.lock"
            )
            guard !locked.isEmpty else { return .notFound }

            if let controllerID = update.networkControllerAgentID {
                let agents = try await session.execute(
                    FindAgentForSiteController(id: controllerID),
                    operation: "sites.update.controller"
                )
                guard agents.count <= 1 else {
                    throw SitesPersistenceError.unexpectedRowCount(expected: 1, actual: agents.count)
                }
                guard let agent = agents.first else { return .controllerNotFound(controllerID) }
                guard agent.siteID == id else { return .controllerOutsideSite(name: agent.name) }
                guard agent.supportsInterVMNetworking else {
                    return .controllerCannotAuthor(name: agent.name)
                }
            }

            let rows = try await session.execute(
                UpdateSite(id: id, update: update),
                operation: "sites.update.query"
            )
            guard rows.count == 1, let row = rows.first else {
                throw SitesPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
            }
            return .updated(row.snapshot)
        }
    }

    public func deleteIfEmpty(id: UUID) async throws -> SiteDeleteResult {
        try await database.withTransaction(operation: "sites.delete") { session in
            let locked = try await session.execute(
                LockSite(id: id),
                operation: "sites.delete.lock"
            )
            guard !locked.isEmpty else { return .notFound }

            let usage = try await session.execute(
                MeasureSiteUsage(id: id),
                operation: "sites.delete.usage"
            )
            guard usage.count == 1, let counts = usage.first else {
                throw SitesPersistenceError.unexpectedRowCount(expected: 1, actual: usage.count)
            }
            if counts.agents > 0 { return .hasAgents(counts.agents) }
            if counts.networks > 0 { return .hasNetworks(counts.networks) }
            if counts.floatingIPPools > 0 { return .hasFloatingIPPools(counts.floatingIPPools) }

            let deleted = try await session.execute(
                DeleteSite(id: id),
                operation: "sites.delete.query"
            )
            guard deleted == [id] else {
                throw SitesPersistenceError.unexpectedRowCount(expected: 1, actual: deleted.count)
            }
            return .deleted
        }
    }

    /// Moves an existing agent into a site while preserving every topology and
    /// workload-placement invariant on one pinned connection.
    public func assignAgent(id agentID: UUID, toSite siteID: UUID) async throws
        -> SiteAgentAssignmentResult
    {
        try await database.withTransaction(operation: "sites.assign_agent") { session in
            let sites = try await session.execute(
                LockSiteAssignmentScope(id: siteID),
                operation: "sites.assign_agent.lock_site"
            )
            guard sites.count <= 1 else {
                throw SitesPersistenceError.unexpectedRowCount(expected: 1, actual: sites.count)
            }
            guard let site = sites.first else { return .siteNotFound }

            let agents = try await session.execute(
                LockAgentForSiteAssignment(id: agentID),
                operation: "sites.assign_agent.lock_agent"
            )
            guard agents.count <= 1 else {
                throw SitesPersistenceError.unexpectedRowCount(expected: 1, actual: agents.count)
            }
            guard let agent = agents.first?.snapshot else { return .agentNotFound }

            let scopeChecks = try await session.execute(
                SiteContainsAgentScope(
                    siteOrganizationID: site.organizationID,
                    siteOrganizationalUnitID: site.organizationalUnitID,
                    agentOrganizationID: agent.organizationID,
                    agentOrganizationalUnitID: agent.organizationalUnitID
                ),
                operation: "sites.assign_agent.scope"
            )
            guard scopeChecks == [true] else { return .outsideScope }

            let controllerships = try await session.execute(
                CountOtherSiteControllerships(agentID: agentID, targetSiteID: siteID),
                operation: "sites.assign_agent.controllerships"
            )
            guard controllerships == [0] else { return .controlsAnotherSite }

            if agent.siteID != siteID {
                let usage = try await session.execute(
                    MeasureHostedWorkloads(agentID: agentID),
                    operation: "sites.assign_agent.workloads"
                )
                guard usage.count == 1, let usage = usage.first else {
                    throw SitesPersistenceError.unexpectedRowCount(expected: 1, actual: usage.count)
                }
                if usage.virtualMachines > 0 {
                    return .hostsVirtualMachines(usage.virtualMachines)
                }
                if usage.sandboxes > 0 { return .hostsSandboxes(usage.sandboxes) }
            }

            let updated = try await session.execute(
                AssignAgentToSite(agentID: agentID, siteID: siteID),
                operation: "sites.assign_agent.update"
            )
            guard updated.count == 1, let assigned = updated.first?.snapshot else {
                throw SitesPersistenceError.unexpectedRowCount(expected: 1, actual: updated.count)
            }

            var newlyDesignatedSiteName: String?
            if assigned.supportsInterVMNetworking {
                let designated = try await session.execute(
                    DesignateSiteControllerIfUnset(siteID: siteID, agentID: agentID),
                    operation: "sites.assign_agent.designate_controller"
                )
                guard designated.count <= 1 else {
                    throw SitesPersistenceError.unexpectedRowCount(
                        expected: 1,
                        actual: designated.count
                    )
                }
                newlyDesignatedSiteName = designated.first
            }

            return .assigned(
                agent: assigned,
                newlyDesignatedSiteName: newlyDesignatedSiteName
            )
        }
    }
}

private struct SiteRecord: Sendable {
    let id: UUID
    let name: String
    let description: String?
    let status: String
    let latitude: Double?
    let longitude: Double?
    let locationLabel: String?
    let regionCode: String?
    let labels: [String: String]
    let networkControllerAgentID: UUID?
    let organizationID: UUID?
    let organizationalUnitID: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let controller: SiteControllerSnapshot?

    init(row: PostgresRow) throws {
        let values = try row.decode((
            UUID, String, String?, String, Double?, Double?, String?, String?, String,
            UUID?, UUID?, UUID?, Date?, Date?, UUID?, String?, String?, Date?,
            String?, [NodeDependencyObservationJSON], Date?
        ).self)
        guard let labelData = values.8.data(using: .utf8),
            let labels = try? JSONDecoder().decode([String: String].self, from: labelData)
        else {
            throw SitesPersistenceError.invalidLabels
        }
        id = values.0
        name = values.1
        description = values.2
        status = values.3
        latitude = values.4
        longitude = values.5
        locationLabel = values.6
        regionCode = values.7
        self.labels = labels
        networkControllerAgentID = values.9
        organizationID = values.10
        organizationalUnitID = values.11
        createdAt = values.12
        updatedAt = values.13
        if let controllerID = values.14, let controllerName = values.15,
            let controllerStatus = values.16
        {
            let observations = values.19.map(\.value)
            let relevant = observations.filter {
                $0.affectedCapabilities.contains(.overlayNetworking)
            }
            let dependenciesAllowOverlay: Bool
            if !relevant.isEmpty, let receivedAt = values.20 {
                dependenciesAllowOverlay = relevant.allSatisfy {
                    $0.allowsNewWork(receivedAt: receivedAt, at: Date(), staleAfter: 60)
                }
            } else {
                dependenciesAllowOverlay = false
            }
            controller = SiteControllerSnapshot(
                id: controllerID,
                name: controllerName,
                status: controllerStatus,
                lastHeartbeat: values.17,
                supportsInterVMNetworking:
                    values.18 == NetworkCapability.overlay.rawValue && dependenciesAllowOverlay
            )
        } else {
            controller = nil
        }
    }

    var snapshot: SiteSnapshot {
        SiteSnapshot(
            id: id,
            name: name,
            description: description,
            status: status,
            latitude: latitude,
            longitude: longitude,
            locationLabel: locationLabel,
            regionCode: regionCode,
            labels: labels,
            networkControllerAgentID: networkControllerAgentID,
            controller: controller,
            organizationID: organizationID,
            organizationalUnitID: organizationalUnitID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct NodeDependencyObservationJSON: Codable, PostgresDecodable,
    PostgresArrayDecodable, Sendable
{
    static let psqlArrayType: PostgresDataType = .jsonbArray
    let value: NodeDependencyObservation

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(NodeDependencyObservation.self)
    }
}

private let siteColumns = """
    s.id, s.name, s.description, s.status, s.latitude, s.longitude,
    s.location_label, s.region_code, s.labels::text,
    s.network_controller_agent_id, s.organization_id, s.organizational_unit_id,
    s.created_at, s.updated_at,
    controller.id, controller.name, controller.status::text,
    controller.last_heartbeat, controller.network_capability,
    COALESCE(controller.dependency_observations, '{}'::jsonb[]),
    controller.dependency_observations_received_at
    """

private let siteFrom = """
    FROM sites AS s
    LEFT JOIN agents AS controller ON controller.id = s.network_controller_agent_id
    """

private protocol SiteStatement: PostgresPreparedStatement where Row == SiteRecord {}

private extension SiteStatement {
    func decodeRow(_ row: PostgresRow) throws -> SiteRecord { try SiteRecord(row: row) }
}

private struct ListSites: SiteStatement {
    static var sql: String { "SELECT \(siteColumns) \(siteFrom) ORDER BY s.name, s.id" }
    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct ListScopedSites: SiteStatement {
    static var sql: String {
        """
        SELECT \(siteColumns) \(siteFrom)
        WHERE s.organization_id = $1
           OR s.organizational_unit_id = ANY($2::uuid[])
        ORDER BY s.name, s.id
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

private struct FindSite: SiteStatement {
    static var sql: String { "SELECT \(siteColumns) \(siteFrom) WHERE s.id = $1" }
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct InsertSite: SiteStatement {
    static var sql: String {
        """
        WITH inserted AS (
            INSERT INTO sites (
                id, name, description, status, latitude, longitude,
                location_label, region_code, labels, network_controller_agent_id,
                organization_id, organizational_unit_id, created_at, updated_at
            )
            SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, NULL,
                   $10, $11, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            WHERE ($10::uuid IS NOT NULL AND $11::uuid IS NULL
                   AND EXISTS (SELECT 1 FROM organizations WHERE id = $10))
               OR ($10::uuid IS NULL AND $11::uuid IS NOT NULL
                   AND EXISTS (SELECT 1 FROM organizational_units WHERE id = $11))
            RETURNING *
        )
        SELECT \(siteColumns)
        FROM inserted AS s
        LEFT JOIN agents AS controller ON false
        """
    }
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .text, .text, .text, .float8, .float8, .text, .text, .text, .uuid, .uuid,
    ]
    let write: SiteWrite
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 11)
        bindings.append(write.id)
        bindings.append(write.name)
        bindings.append(write.description)
        bindings.append(write.status)
        bindings.append(write.latitude)
        bindings.append(write.longitude)
        bindings.append(write.locationLabel)
        bindings.append(write.regionCode)
        bindings.append(String(data: try JSONEncoder().encode(write.labels), encoding: .utf8)!)
        bindings.append(write.organizationID)
        bindings.append(write.organizationalUnitID)
        return bindings
    }
}

private struct LockSite: PostgresPreparedStatement {
    static let sql = "SELECT id FROM sites WHERE id = $1 FOR UPDATE"
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct SiteControllerCandidate: Sendable {
    let name: String
    let siteID: UUID
    let supportsInterVMNetworking: Bool
}

private struct FindAgentForSiteController: PostgresPreparedStatement {
    static let sql = """
        SELECT name, site_id, network_capability,
               dependency_observations, dependency_observations_received_at
        FROM agents WHERE id = $1
        """
    typealias Row = SiteControllerCandidate
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> SiteControllerCandidate {
        let value = try row.decode(
            (String, UUID, String?, [NodeDependencyObservationJSON], Date?).self
        )
        let relevant = value.3.map(\.value).filter {
            $0.affectedCapabilities.contains(.overlayNetworking)
        }
        let dependenciesAllow: Bool
        if !relevant.isEmpty, let receivedAt = value.4 {
            dependenciesAllow = relevant.allSatisfy {
                $0.allowsNewWork(receivedAt: receivedAt, at: Date(), staleAfter: 60)
            }
        } else {
            dependenciesAllow = false
        }
        return SiteControllerCandidate(
            name: value.0,
            siteID: value.1,
            supportsInterVMNetworking:
                value.2 == NetworkCapability.overlay.rawValue && dependenciesAllow
        )
    }
}

private struct UpdateSite: SiteStatement {
    static var sql: String {
        """
        WITH updated AS (
            UPDATE sites SET
                description = $2,
                network_controller_agent_id = $3,
                status = COALESCE($4, status),
                latitude = $5,
                longitude = $6,
                location_label = $7,
                region_code = $8,
                labels = $9::jsonb,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = $1
            RETURNING *
        )
        SELECT \(siteColumns)
        FROM updated AS s
        LEFT JOIN agents AS controller ON controller.id = s.network_controller_agent_id
        """
    }
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .text, .uuid, .text, .float8, .float8, .text, .text, .text,
    ]
    let id: UUID
    let update: SiteUpdate
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 9)
        bindings.append(id)
        bindings.append(update.description)
        bindings.append(update.networkControllerAgentID)
        bindings.append(update.status)
        bindings.append(update.latitude)
        bindings.append(update.longitude)
        bindings.append(update.locationLabel)
        bindings.append(update.regionCode)
        bindings.append(String(data: try JSONEncoder().encode(update.labels), encoding: .utf8)!)
        return bindings
    }
}

private struct SiteUsage: Sendable {
    let agents: Int
    let networks: Int
    let floatingIPPools: Int
}

private struct MeasureSiteUsage: PostgresPreparedStatement {
    static let sql = """
        SELECT
            (SELECT count(*)::bigint FROM agents WHERE site_id = $1),
            (SELECT count(*)::bigint FROM logical_networks WHERE site_id = $1),
            (SELECT count(*)::bigint FROM floating_ip_pools WHERE site_id = $1)
        """
    typealias Row = SiteUsage
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> SiteUsage {
        let value = try row.decode((Int, Int, Int).self)
        return SiteUsage(agents: value.0, networks: value.1, floatingIPPools: value.2)
    }
}

private struct CountSiteAgents: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM agents WHERE site_id = $1"
    typealias Row = Int
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct DeleteSite: PostgresPreparedStatement {
    static let sql = "DELETE FROM sites WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct SiteAssignmentScope: Sendable {
    let organizationID: UUID?
    let organizationalUnitID: UUID?
}

private struct LockSiteAssignmentScope: PostgresPreparedStatement {
    static let sql = """
        SELECT organization_id, organizational_unit_id
        FROM sites WHERE id = $1 FOR UPDATE
        """
    typealias Row = SiteAssignmentScope
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> SiteAssignmentScope {
        let value = try row.decode((UUID?, UUID?).self)
        return SiteAssignmentScope(organizationID: value.0, organizationalUnitID: value.1)
    }
}

private struct LockAgentForSiteAssignment: AgentStatement {
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

private struct SiteContainsAgentScope: PostgresPreparedStatement {
    static let sql = """
        SELECT CASE
            WHEN $1::uuid IS NOT NULL THEN
                $3::uuid = $1
                OR EXISTS (
                    SELECT 1 FROM organizational_units
                    WHERE id = $4 AND organization_id = $1
                )
            WHEN $2::uuid IS NOT NULL AND $4::uuid IS NOT NULL THEN EXISTS (
                WITH RECURSIVE ancestry AS (
                    SELECT id, parent_id
                    FROM organizational_units WHERE id = $4
                    UNION ALL
                    SELECT parent.id, parent.parent_id
                    FROM organizational_units AS parent
                    JOIN ancestry AS child ON parent.id = child.parent_id
                )
                SELECT 1 FROM ancestry WHERE id = $2
            )
            ELSE FALSE
        END
        """
    static let bindingDataTypes: [PostgresDataType] = [.uuid, .uuid, .uuid, .uuid]
    typealias Row = Bool
    let siteOrganizationID: UUID?
    let siteOrganizationalUnitID: UUID?
    let agentOrganizationID: UUID?
    let agentOrganizationalUnitID: UUID?
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(siteOrganizationID)
        bindings.append(siteOrganizationalUnitID)
        bindings.append(agentOrganizationID)
        bindings.append(agentOrganizationalUnitID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private struct CountOtherSiteControllerships: PostgresPreparedStatement {
    static let sql = """
        SELECT count(*)::bigint FROM sites
        WHERE network_controller_agent_id = $1 AND id <> $2
        """
    typealias Row = Int
    let agentID: UUID
    let targetSiteID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(agentID)
        bindings.append(targetSiteID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct HostedWorkloadUsage: Sendable {
    let virtualMachines: Int
    let sandboxes: Int
}

private struct MeasureHostedWorkloads: PostgresPreparedStatement {
    static let sql = """
        SELECT
            (SELECT count(*)::bigint FROM vms WHERE hypervisor_id = $1),
            (SELECT count(*)::bigint FROM sandboxes WHERE hypervisor_id = $1)
        """
    static let bindingDataTypes: [PostgresDataType] = [.text]
    typealias Row = HostedWorkloadUsage
    let agentID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(agentID.uuidString)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> HostedWorkloadUsage {
        let value = try row.decode((Int, Int).self)
        return HostedWorkloadUsage(virtualMachines: value.0, sandboxes: value.1)
    }
}

private struct AssignAgentToSite: AgentStatement {
    static var sql: String {
        """
        WITH updated AS (
            UPDATE agents SET site_id = $2, updated_at = CURRENT_TIMESTAMP
            WHERE id = $1
            RETURNING *
        )
        SELECT \(agentColumns) FROM updated AS a
        """
    }
    let agentID: UUID
    let siteID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(agentID)
        bindings.append(siteID)
        return bindings
    }
}

private struct DesignateSiteControllerIfUnset: PostgresPreparedStatement {
    static let sql = """
        UPDATE sites
        SET network_controller_agent_id = $2, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND network_controller_agent_id IS NULL
        RETURNING name
        """
    typealias Row = String
    let siteID: UUID
    let agentID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(siteID)
        bindings.append(agentID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> String { try row.decode(String.self) }
}
