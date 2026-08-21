import Foundation
import PostgresNIO

public struct OrgTrustDomainSnapshot: Equatable, Sendable {
    public let id: UUID
    public let organizationID: UUID
    public let trustDomain: String
    public let phase: String
    public let generation: Int64
    public let observedGeneration: Int64
    public let serverAddress: String?
    public let bundleEndpointURL: String?
    public let nodeAddress: String?
    public let orgBundlePEM: String?
    public let lastError: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let deletedAt: Date?

    public var acceptsIdentities: Bool { phase == "active" && orgBundlePEM != nil }
}

public struct OrgTrustDomainState: Sendable {
    public let phase: String
    public let generation: Int64
    public let observedGeneration: Int64
    public let serverAddress: String?
    public let bundleEndpointURL: String?
    public let nodeAddress: String?
    public let orgBundlePEM: String?
    public let lastError: String?
    public let deletedAt: Date?

    public init(
        phase: String,
        generation: Int64,
        observedGeneration: Int64,
        serverAddress: String?,
        bundleEndpointURL: String?,
        nodeAddress: String?,
        orgBundlePEM: String?,
        lastError: String?,
        deletedAt: Date?
    ) {
        self.phase = phase
        self.generation = generation
        self.observedGeneration = observedGeneration
        self.serverAddress = serverAddress
        self.bundleEndpointURL = bundleEndpointURL
        self.nodeAddress = nodeAddress
        self.orgBundlePEM = orgBundlePEM
        self.lastError = lastError
        self.deletedAt = deletedAt
    }
}

public enum OrgTrustDomainsPersistenceError: Error, Equatable, Sendable {
    case unexpectedRowCount(expected: Int, actual: Int)
}

public struct OrgTrustDomainsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) { self.database = database }

    public func trustDomain(organizationID: UUID) async throws -> OrgTrustDomainSnapshot? {
        try await database.withSession(operation: "org_trust_domains.lookup_organization") { session in
            try oneOrNone(await session.execute(
                FindOrgTrustDomainByOrganization(organizationID: organizationID),
                operation: "org_trust_domains.lookup_organization.query"))
        }
    }

    public func trustDomain(named trustDomain: String) async throws -> OrgTrustDomainSnapshot? {
        try await database.withSession(operation: "org_trust_domains.lookup_name") { session in
            try oneOrNone(await session.execute(
                FindOrgTrustDomainByName(trustDomain: trustDomain),
                operation: "org_trust_domains.lookup_name.query"))
        }
    }

    public func activeTrustDomains() async throws -> [OrgTrustDomainSnapshot] {
        try await database.withSession(operation: "org_trust_domains.list_active") { session in
            try await session.execute(
                ListActiveOrgTrustDomains(),
                operation: "org_trust_domains.list_active.query")
        }
    }

    public func updateState(id: UUID, state: OrgTrustDomainState) async throws
        -> OrgTrustDomainSnapshot?
    {
        try await database.withSession(operation: "org_trust_domains.update_state") { session in
            try oneOrNone(await session.execute(
                UpdateOrgTrustDomainState(id: id, state: state),
                operation: "org_trust_domains.update_state.query"))
        }
    }

    public func markForTeardown(organizationID: UUID) async throws -> OrgTrustDomainSnapshot? {
        try await database.withSession(operation: "org_trust_domains.mark_for_teardown") { session in
            try oneOrNone(await session.execute(
                MarkOrgTrustDomainForTeardown(organizationID: organizationID),
                operation: "org_trust_domains.mark_for_teardown.query"))
        }
    }

    private func oneOrNone<T>(_ rows: [T]) throws -> T? {
        guard rows.count <= 1 else {
            throw OrgTrustDomainsPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first
    }
}

private let orgTrustDomainColumns = """
    id, organization_id, trust_domain, phase::text AS phase,
    generation, observed_generation, server_address, bundle_endpoint_url,
    node_address, org_bundle_pem, last_error, created_at, updated_at, deleted_at
    """

private protocol OrgTrustDomainStatement: PostgresPreparedStatement
where Row == OrgTrustDomainSnapshot {}

extension OrgTrustDomainStatement {
    func decodeRow(_ row: PostgresRow) throws -> OrgTrustDomainSnapshot {
        let row = row.makeRandomAccess()
        return OrgTrustDomainSnapshot(
            id: try row["id"].decode(UUID.self),
            organizationID: try row["organization_id"].decode(UUID.self),
            trustDomain: try row["trust_domain"].decode(String.self),
            phase: try row["phase"].decode(String.self),
            generation: try row["generation"].decode(Int64.self),
            observedGeneration: try row["observed_generation"].decode(Int64.self),
            serverAddress: try row["server_address"].decode(String?.self),
            bundleEndpointURL: try row["bundle_endpoint_url"].decode(String?.self),
            nodeAddress: try row["node_address"].decode(String?.self),
            orgBundlePEM: try row["org_bundle_pem"].decode(String?.self),
            lastError: try row["last_error"].decode(String?.self),
            createdAt: try row["created_at"].decode(Date?.self),
            updatedAt: try row["updated_at"].decode(Date?.self),
            deletedAt: try row["deleted_at"].decode(Date?.self))
    }
}

private struct FindOrgTrustDomainByOrganization: OrgTrustDomainStatement {
    static var sql: String {
        "SELECT \(orgTrustDomainColumns) FROM org_trust_domains WHERE organization_id = $1"
    }
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(organizationID)
        return bindings
    }
}

private struct FindOrgTrustDomainByName: OrgTrustDomainStatement {
    static var sql: String {
        "SELECT \(orgTrustDomainColumns) FROM org_trust_domains WHERE trust_domain = $1"
    }
    let trustDomain: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(trustDomain)
        return bindings
    }
}

private struct ListActiveOrgTrustDomains: OrgTrustDomainStatement {
    static var sql: String {
        "SELECT \(orgTrustDomainColumns) FROM org_trust_domains WHERE phase = 'active' ORDER BY id"
    }
    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct UpdateOrgTrustDomainState: OrgTrustDomainStatement {
    static var sql: String {
        """
        UPDATE org_trust_domains
        SET phase = $2::org_trust_domain_phase, generation = $3, observed_generation = $4,
            server_address = $5, bundle_endpoint_url = $6, node_address = $7,
            org_bundle_pem = $8, last_error = $9, deleted_at = $10,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(orgTrustDomainColumns)
        """
    }
    let id: UUID
    let state: OrgTrustDomainState
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 10)
        bindings.append(id)
        bindings.append(state.phase)
        bindings.append(state.generation)
        bindings.append(state.observedGeneration)
        bindings.append(state.serverAddress)
        bindings.append(state.bundleEndpointURL)
        bindings.append(state.nodeAddress)
        bindings.append(state.orgBundlePEM)
        bindings.append(state.lastError)
        bindings.append(state.deletedAt)
        return bindings
    }
}

private struct MarkOrgTrustDomainForTeardown: OrgTrustDomainStatement {
    static var sql: String {
        """
        UPDATE org_trust_domains
        SET phase = 'deleting', deleted_at = CURRENT_TIMESTAMP, last_error = NULL,
            generation = generation + 1, updated_at = CURRENT_TIMESTAMP
        WHERE organization_id = $1
        RETURNING \(orgTrustDomainColumns)
        """
    }
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(organizationID)
        return bindings
    }
}
