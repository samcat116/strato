import Foundation
import PostgresNIO

public struct WorkloadRegistrationSnapshot: Equatable, Sendable {
    public let id: UUID
    public let spiffeID: String
    public let kind: String
    public let agentName: String?
    public let serviceAccountID: UUID?
    public let organizationID: UUID?
    public let displayName: String?
    public let createdBy: UUID?
    public let createdAt: Date?
    public let vmID: UUID?
}

public struct WorkloadRegistrationWrite: Equatable, Sendable {
    public let id: UUID
    public let spiffeID: String
    public let kind: String
    public let agentName: String?
    public let serviceAccountID: UUID?
    public let organizationID: UUID?
    public let displayName: String?
    public let createdBy: UUID?
    public let vmID: UUID?

    public init(
        id: UUID = UUID(),
        spiffeID: String,
        kind: String,
        agentName: String? = nil,
        serviceAccountID: UUID? = nil,
        organizationID: UUID? = nil,
        displayName: String? = nil,
        createdBy: UUID? = nil,
        vmID: UUID? = nil
    ) {
        self.id = id
        self.spiffeID = spiffeID
        self.kind = kind
        self.agentName = agentName
        self.serviceAccountID = serviceAccountID
        self.organizationID = organizationID
        self.displayName = displayName
        self.createdBy = createdBy
        self.vmID = vmID
    }
}

public struct WorkloadPrincipalSnapshot: Equatable, Sendable {
    public let id: UUID
    public let spiffeID: String
    public let vmID: UUID?
    public let vmName: String?
    public let displayName: String?
}

public struct ProjectVMPrincipalSnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let spiffeID: String?
    public let principalID: UUID?
    public let createdAt: Date?
}

public struct HeldWorkloadClaimSnapshot: Equatable, Sendable {
    public let resourceKind: String
    public let resourceID: UUID
    public let reason: String?
    public let observedStatus: String?
    public let firstSeenAt: Date?

    public var placedOnAgentID: String? {
        guard let reason, reason.hasPrefix("row_on_agent:") else { return nil }
        return String(reason.dropFirst("row_on_agent:".count))
    }
}

public enum WorkloadClaimDisposition: String, Codable, Sendable {
    case tombstoned
    case held
}

public struct WorkloadClaimSnapshot: Equatable, Sendable {
    public let id: UUID
    public let agentID: String
    public let resourceKind: String
    public let resourceID: UUID
    public let disposition: WorkloadClaimDisposition
    public let tombstoneGeneration: Int64?
    public let reason: String?
    public let observedGeneration: Int64
    public let observedStatus: String?
    public let firstSeenAt: Date?
    public let lastSeenAt: Date?

    public var placedOnAgentID: String? {
        guard disposition == .held, let reason, reason.hasPrefix("row_on_agent:") else { return nil }
        return String(reason.dropFirst("row_on_agent:".count))
    }
}

public struct WorkloadClaimWrite: Codable, Equatable, Sendable {
    public let id: UUID
    public let agentID: String
    public let resourceKind: String
    public let resourceID: UUID
    public let disposition: WorkloadClaimDisposition
    public let tombstoneGeneration: Int64?
    public let reason: String?
    public let observedGeneration: Int64
    public let observedStatus: String?

    public init(
        id: UUID = UUID(),
        agentID: String,
        resourceKind: String,
        resourceID: UUID,
        disposition: WorkloadClaimDisposition,
        tombstoneGeneration: Int64? = nil,
        reason: String? = nil,
        observedGeneration: Int64,
        observedStatus: String? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.resourceKind = resourceKind
        self.resourceID = resourceID
        self.disposition = disposition
        self.tombstoneGeneration = tombstoneGeneration
        self.reason = reason
        self.observedGeneration = observedGeneration
        self.observedStatus = observedStatus
    }
}

public struct WorkloadAdoptionResult: Equatable, Sendable {
    public let adoptedVMs: Int
    public let adoptedSandboxes: Int
    public let adoptedVolumes: Int
    public let skippedUnclaimed: Int
}

public struct ObservedInterfaceAddressSnapshot: Equatable, Sendable {
    public let id: UUID
    public let interfaceID: UUID
    public let family: String
    public let address: String
    public let prefixLength: Int?
    public let createdAt: Date?
    public let updatedAt: Date?
}

public struct ObservedInterfaceAddressWrite: Equatable, Sendable {
    public let family: String
    public let address: String
    public let prefixLength: Int?

    public init(family: String, address: String, prefixLength: Int?) {
        self.family = family
        self.address = address
        self.prefixLength = prefixLength
    }
}

public enum WorkloadsPersistenceError: Error, Equatable, Sendable {
    case invalidClaimDisposition(String)
    case unexpectedRowCount(expected: Int, actual: Int)
    case noMatchingClaims
    case duplicateSPIFFEID(String)
    case spiffeIDOwnedByDifferentPrincipal(String)
}

/// Read-side workload identity facts used by IAM management surfaces. The
/// lifecycle and reconciliation operations join this module in their cohort.
public struct WorkloadsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func registration(id: UUID) async throws -> WorkloadRegistrationSnapshot? {
        try await database.withSession(operation: "workloads.registrations.lookup") { session in
            try oneOrNone(
                await session.execute(
                    FindWorkloadRegistration(id: id),
                    operation: "workloads.registrations.lookup.query"))
        }
    }

    public func registration(spiffeID: String) async throws -> WorkloadRegistrationSnapshot? {
        try await database.withSession(operation: "workloads.registrations.lookup_spiffe") {
            session in
            try oneOrNone(
                await session.execute(
                    FindWorkloadRegistrationBySPIFFEID(spiffeID: spiffeID),
                    operation: "workloads.registrations.lookup_spiffe.query"))
        }
    }

    public func registrations(
        kind: String? = nil,
        spiffeID: String? = nil,
        vmOwned: Bool? = nil
    ) async throws -> [WorkloadRegistrationSnapshot] {
        try await database.withSession(operation: "workloads.registrations.list") { session in
            try await session.execute(
                ListWorkloadRegistrations(kind: kind, spiffeID: spiffeID, vmOwned: vmOwned),
                operation: "workloads.registrations.list.query")
        }
    }

    public func registrations(
        serviceAccountID: UUID
    ) async throws -> [WorkloadRegistrationSnapshot] {
        try await database.withSession(operation: "workloads.registrations.list_account") {
            session in
            try await session.execute(
                ListServiceAccountWorkloadRegistrations(serviceAccountID: serviceAccountID),
                operation: "workloads.registrations.list_account.query")
        }
    }

    public func registrations(vmIDs: [UUID]) async throws -> [WorkloadRegistrationSnapshot] {
        guard !vmIDs.isEmpty else { return [] }
        return try await database.withSession(operation: "workloads.registrations.list_vms") {
            session in
            try await session.execute(
                ListVMWorkloadRegistrations(vmIDs: Array(Set(vmIDs))),
                operation: "workloads.registrations.list_vms.query")
        }
    }

    public func vmNames(ids: [UUID]) async throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        let rows = try await database.withSession(operation: "workloads.vm_names.lookup") { session in
            try await session.execute(
                FindVMNames(ids: Array(Set(ids))),
                operation: "workloads.vm_names.lookup.query")
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.name) })
    }

    public func createRegistration(
        _ write: WorkloadRegistrationWrite
    ) async throws -> WorkloadRegistrationSnapshot {
        do {
            return try await database.withSession(operation: "workloads.registrations.create") {
                session in
                try only(
                    await session.execute(
                        InsertWorkloadRegistration(write: write),
                        operation: "workloads.registrations.create.query"))
            }
        } catch let error as PSQLError
            where workloadConstraint(error, named: "uq:workload_registrations.spiffe_id")
        {
            throw WorkloadsPersistenceError.duplicateSPIFFEID(write.spiffeID)
        }
    }

    /// Establishes the first-seen agent mapping and verifies every later use.
    /// The insert and authoritative read share one transaction, so concurrent
    /// first connections converge on the unique SPIFFE-ID row.
    public func requireAgentRegistration(
        spiffeID: String,
        agentName: String
    ) async throws {
        try await database.withTransaction(operation: "workloads.registrations.require_agent") {
            session in
            _ = try await session.execute(
                InsertAgentRegistrationIfAbsent(
                    id: UUID(), spiffeID: spiffeID, agentName: agentName),
                operation: "workloads.registrations.require_agent.insert")
            let rows = try await session.execute(
                FindWorkloadRegistrationBySPIFFEID(spiffeID: spiffeID),
                operation: "workloads.registrations.require_agent.lookup")
            guard rows.count == 1, rows[0].kind == "agent", rows[0].agentName == agentName else {
                throw WorkloadsPersistenceError.spiffeIDOwnedByDifferentPrincipal(spiffeID)
            }
        }
    }

    @discardableResult
    public func deleteAgentRegistration(spiffeID: String) async throws -> Bool {
        try await database.withSession(operation: "workloads.registrations.delete_agent") { session in
            try await session.execute(
                DeleteAgentRegistration(spiffeID: spiffeID),
                operation: "workloads.registrations.delete_agent.query").count == 1
        }
    }

    @discardableResult
    public func deleteRegistration(
        id: UUID,
        serviceAccountID: UUID? = nil
    ) async throws -> Bool {
        try await database.withSession(operation: "workloads.registrations.delete") { session in
            try await session.execute(
                DeleteWorkloadRegistration(id: id, serviceAccountID: serviceAccountID),
                operation: "workloads.registrations.delete.query").count == 1
        }
    }

    /// Removes a directly registered workload principal and all of its grants
    /// in one transaction. Other registration kinds keep their existing
    /// foreign-key ownership semantics and are deleted without grant cleanup.
    @discardableResult
    public func revokeRegistration(id: UUID, kind: String) async throws -> Bool {
        try await database.withTransaction(operation: "workloads.registrations.revoke") { session in
            if kind == "workload" {
                _ = try await session.execute(
                    DeleteWorkloadRoleBindings(principalID: id),
                    operation: "workloads.registrations.revoke.bindings")
            }
            return try await session.execute(
                DeleteWorkloadRegistration(id: id, serviceAccountID: nil),
                operation: "workloads.registrations.revoke.registration").count == 1
        }
    }

    public func workloadPrincipals(ids: [UUID]) async throws -> [WorkloadPrincipalSnapshot] {
        guard !ids.isEmpty else { return [] }
        return try await database.withSession(operation: "workloads.principals.lookup") { session in
            try await session.execute(
                FindWorkloadPrincipals(ids: Array(Set(ids))),
                operation: "workloads.principals.lookup.query"
            )
        }
    }

    public func vmPrincipals(projectID: UUID) async throws -> [ProjectVMPrincipalSnapshot] {
        try await database.withSession(operation: "workloads.vm_principals.list") { session in
            try await session.execute(
                ListProjectVMPrincipals(projectID: projectID),
                operation: "workloads.vm_principals.list.query"
            )
        }
    }

    public func heldClaims(agentID: UUID) async throws -> [HeldWorkloadClaimSnapshot] {
        try await database.withSession(operation: "workloads.held_claims.list") { session in
            try await session.execute(
                ListHeldWorkloadClaims(agentID: agentID.uuidString),
                operation: "workloads.held_claims.list.query"
            )
        }
    }

    public func claims(
        agentID: String,
        disposition: WorkloadClaimDisposition? = nil
    ) async throws -> [WorkloadClaimSnapshot] {
        try await database.withSession(operation: "workloads.claims.list") { session in
            if let disposition {
                return try await session.execute(
                    ListWorkloadClaimsByDisposition(agentID: agentID, disposition: disposition),
                    operation: "workloads.claims.list_filtered.query")
            }
            return try await session.execute(
                ListWorkloadClaims(agentID: agentID),
                operation: "workloads.claims.list.query")
        }
    }

    public func countClaims(agentID: String) async throws -> Int {
        try await database.withSession(operation: "workloads.claims.count") { session in
            try only(
                await session.execute(
                    CountWorkloadClaims(agentID: agentID),
                    operation: "workloads.claims.count.query"))
        }
    }

    public func observedInterfaceAddresses(
        interfaceIDs: [UUID]
    ) async throws -> [ObservedInterfaceAddressSnapshot] {
        guard !interfaceIDs.isEmpty else { return [] }
        return try await database.withSession(operation: "workloads.observed_addresses.list") { session in
            try await session.execute(
                ListObservedInterfaceAddresses(interfaceIDs: Array(Set(interfaceIDs))),
                operation: "workloads.observed_addresses.list.query")
        }
    }

    /// Replaces one interface's guest-reported address set atomically. UUIDs
    /// remain application-generated while PostgreSQL owns both timestamps.
    public func replaceObservedInterfaceAddresses(
        interfaceID: UUID,
        addresses: [ObservedInterfaceAddressWrite]
    ) async throws {
        try await database.withTransaction(operation: "workloads.observed_addresses.replace") { session in
            _ = try await session.execute(
                DeleteObservedInterfaceAddresses(interfaceIDs: [interfaceID]),
                operation: "workloads.observed_addresses.replace.delete")
            for address in addresses {
                let inserted = try await session.execute(
                    InsertObservedInterfaceAddress(
                        id: UUID(), interfaceID: interfaceID, address: address),
                    operation: "workloads.observed_addresses.replace.insert")
                guard inserted.count == 1 else {
                    throw WorkloadsPersistenceError.unexpectedRowCount(
                        expected: 1, actual: inserted.count)
                }
            }
        }
    }

    /// Transaction-scoped counterpart used when observed-state reconciliation
    /// already holds the owning VM row lock. Reusing that context preserves
    /// atomicity and avoids a nested pool lease.
    public func replaceObservedInterfaceAddresses(
        interfaceID: UUID,
        addresses: [ObservedInterfaceAddressWrite],
        on context: PostgresStoreContext
    ) async throws {
        _ = try await context.execute(
            DeleteObservedInterfaceAddresses(interfaceIDs: [interfaceID]),
            operation: "workloads.observed_addresses.replace.delete")
        for address in addresses {
            let inserted = try await context.execute(
                InsertObservedInterfaceAddress(
                    id: UUID(), interfaceID: interfaceID, address: address),
                operation: "workloads.observed_addresses.replace.insert")
            guard inserted.count == 1 else {
                throw WorkloadsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: inserted.count)
            }
        }
    }

    @discardableResult
    public func deleteObservedInterfaceAddresses(interfaceIDs: [UUID]) async throws -> [UUID] {
        guard !interfaceIDs.isEmpty else { return [] }
        return try await database.withSession(operation: "workloads.observed_addresses.delete") { session in
            try await session.execute(
                DeleteObservedInterfaceAddresses(interfaceIDs: Array(Set(interfaceIDs))),
                operation: "workloads.observed_addresses.delete.query")
        }
    }

    /// Delete observed addresses on an already-pinned transaction context.
    @discardableResult
    public func deleteObservedInterfaceAddresses(
        interfaceIDs: [UUID],
        on context: PostgresStoreContext
    ) async throws -> [UUID] {
        guard !interfaceIDs.isEmpty else { return [] }
        return try await context.execute(
            DeleteObservedInterfaceAddresses(interfaceIDs: Array(Set(interfaceIDs))),
            operation: "workloads.observed_addresses.delete.query")
    }

    /// Inserts one report's new claims with one prepared statement. JSON is a
    /// bound transport for the variable-size batch; SQL structure never
    /// changes and PostgreSQL owns both timestamps.
    public func insertClaims(_ writes: [WorkloadClaimWrite]) async throws {
        guard !writes.isEmpty else { return }
        let data = try JSONEncoder().encode(writes)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw WorkloadsPersistenceError.unexpectedRowCount(expected: writes.count, actual: 0)
        }
        try await database.withSession(operation: "workloads.claims.insert") { session in
            let inserted = try await session.execute(
                InsertWorkloadClaims(payload: payload),
                operation: "workloads.claims.insert.query")
            guard inserted.count == writes.count else {
                throw WorkloadsPersistenceError.unexpectedRowCount(
                    expected: writes.count, actual: inserted.count)
            }
        }
    }

    public func updateClaim(
        id: UUID,
        disposition: WorkloadClaimDisposition,
        tombstoneGeneration: Int64?,
        reason: String?,
        observedGeneration: Int64,
        observedStatus: String?
    ) async throws {
        try await database.withSession(operation: "workloads.claims.update") { session in
            let updated = try await session.execute(
                UpdateWorkloadClaim(
                    id: id,
                    disposition: disposition,
                    tombstoneGeneration: tombstoneGeneration,
                    reason: reason,
                    observedGeneration: observedGeneration,
                    observedStatus: observedStatus),
                operation: "workloads.claims.update.query")
            guard updated.count == 1 else {
                throw WorkloadsPersistenceError.unexpectedRowCount(expected: 1, actual: updated.count)
            }
        }
    }

    @discardableResult
    public func deleteClaims(ids: [UUID]) async throws -> [UUID] {
        guard !ids.isEmpty else { return [] }
        return try await database.withSession(operation: "workloads.claims.delete") { session in
            try await session.execute(
                DeleteWorkloadClaims(ids: ids),
                operation: "workloads.claims.delete.query")
        }
    }

    /// Re-points only workloads supported by held-claim evidence, then consumes
    /// that evidence in the same native transaction. Volume replica movement
    /// remains atomic with VM and sandbox placement.
    public func adoptWorkloads(targetAgentID: String, sourceAgentID: String) async throws
        -> WorkloadAdoptionResult
    {
        try await database.withTransaction(operation: "workloads.adopt") { session in
            let claims = try await session.execute(
                LockAdoptableWorkloadClaims(
                    targetAgentID: targetAgentID,
                    sourceReason: "row_on_agent:\(sourceAgentID)"),
                operation: "workloads.adopt.claims")
            guard !claims.isEmpty else { throw WorkloadsPersistenceError.noMatchingClaims }

            let claimedVMIDs = claims.filter { $0.resourceKind == "virtual_machine" }.map(\.resourceID)
            let claimedSandboxIDs = claims.filter { $0.resourceKind == "sandbox" }.map(\.resourceID)

            let sourceCounts = try only(
                await session.execute(
                    CountSourceWorkloads(
                        sourceAgentID: sourceAgentID),
                    operation: "workloads.adopt.source_counts"))

            let adoptedVMs = try await session.execute(
                RepointVMs(
                    sourceAgentID: sourceAgentID,
                    targetAgentID: targetAgentID,
                    ids: claimedVMIDs),
                operation: "workloads.adopt.vms")
            let adoptedSandboxes = try await session.execute(
                RepointSandboxes(
                    sourceAgentID: sourceAgentID,
                    targetAgentID: targetAgentID,
                    ids: claimedSandboxIDs),
                operation: "workloads.adopt.sandboxes")

            let movableVolumes = try await session.execute(
                FindMovableSourceVolumes(
                    sourceAgentID: sourceAgentID,
                    claimedVMIDs: claimedVMIDs),
                operation: "workloads.adopt.volumes.lookup")
            let movableVolumeIDs = movableVolumes.map(\.id)
            if !movableVolumeIDs.isEmpty {
                _ = try await session.execute(
                    RepointAttachedVolumes(
                        sourceAgentID: sourceAgentID,
                        targetAgentID: targetAgentID,
                        ids: movableVolumeIDs),
                    operation: "workloads.adopt.volumes.update")
                _ = try await session.execute(
                    DeleteRedundantSourceReplicas(
                        sourceAgentID: sourceAgentID,
                        targetAgentID: targetAgentID,
                        volumeIDs: movableVolumeIDs),
                    operation: "workloads.adopt.replicas.delete_redundant")
                _ = try await session.execute(
                    RepointSourceReplicas(
                        sourceAgentID: sourceAgentID,
                        targetAgentID: targetAgentID,
                        volumeIDs: movableVolumeIDs),
                    operation: "workloads.adopt.replicas.update")
            }

            let consumed = try await session.execute(
                DeleteWorkloadClaims(ids: claims.map(\.id)),
                operation: "workloads.adopt.claims.consume")
            guard consumed.count == claims.count else {
                throw WorkloadsPersistenceError.unexpectedRowCount(
                    expected: claims.count, actual: consumed.count)
            }

            return WorkloadAdoptionResult(
                adoptedVMs: adoptedVMs.count,
                adoptedSandboxes: adoptedSandboxes.count,
                adoptedVolumes: movableVolumes.count,
                skippedUnclaimed: sourceCounts.vms - adoptedVMs.count
                    + sourceCounts.sandboxes - adoptedSandboxes.count)
        }
    }

    private func only<Value>(_ rows: [Value]) throws -> Value {
        guard rows.count == 1, let value = rows.first else {
            throw WorkloadsPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return value
    }

    private func oneOrNone<Value>(_ rows: [Value]) throws -> Value? {
        guard rows.count <= 1 else {
            throw WorkloadsPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first
    }
}

private let workloadRegistrationColumns = """
    id, spiffe_id, kind::text, agent_name, service_account_id, organization_id,
    display_name, created_by, created_at, vm_id
    """

private protocol WorkloadRegistrationStatement: PostgresPreparedStatement
    where Row == WorkloadRegistrationSnapshot {}

private extension WorkloadRegistrationStatement {
    func decodeRow(_ row: PostgresRow) throws -> WorkloadRegistrationSnapshot {
        let value = try row.decode(
            (UUID, String, String, String?, UUID?, UUID?, String?, UUID?, Date?, UUID?).self)
        return WorkloadRegistrationSnapshot(
            id: value.0,
            spiffeID: value.1,
            kind: value.2,
            agentName: value.3,
            serviceAccountID: value.4,
            organizationID: value.5,
            displayName: value.6,
            createdBy: value.7,
            createdAt: value.8,
            vmID: value.9)
    }
}

private struct FindWorkloadRegistration: WorkloadRegistrationStatement {
    static let sql = """
        SELECT \(workloadRegistrationColumns)
        FROM workload_registrations
        WHERE id = $1
        """
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct FindWorkloadRegistrationBySPIFFEID: WorkloadRegistrationStatement {
    static let sql = """
        SELECT \(workloadRegistrationColumns)
        FROM workload_registrations
        WHERE spiffe_id = $1
        """
    let spiffeID: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(spiffeID)
        return bindings
    }
}

private struct ListWorkloadRegistrations: WorkloadRegistrationStatement {
    static let sql = """
        SELECT \(workloadRegistrationColumns)
        FROM workload_registrations
        WHERE ($1::text IS NULL OR kind::text = $1)
          AND ($2::text IS NULL OR spiffe_id = $2)
          AND ($3::boolean IS NULL OR (vm_id IS NOT NULL) = $3)
        ORDER BY spiffe_id, id
        """
    let kind: String?
    let spiffeID: String?
    let vmOwned: Bool?
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(kind)
        bindings.append(spiffeID)
        bindings.append(vmOwned)
        return bindings
    }
}

private struct ListServiceAccountWorkloadRegistrations: WorkloadRegistrationStatement {
    static let sql = """
        SELECT \(workloadRegistrationColumns)
        FROM workload_registrations
        WHERE service_account_id = $1
        ORDER BY spiffe_id, id
        """
    let serviceAccountID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(serviceAccountID)
        return bindings
    }
}

private struct ListVMWorkloadRegistrations: WorkloadRegistrationStatement {
    static let sql = """
        SELECT \(workloadRegistrationColumns)
        FROM workload_registrations
        WHERE vm_id = ANY($1)
        ORDER BY vm_id, id
        """
    let vmIDs: [UUID]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(vmIDs)
        return bindings
    }
}

private struct VMNameRow: Sendable {
    let id: UUID
    let name: String
}

private struct FindVMNames: PostgresPreparedStatement {
    static let sql = "SELECT id, name FROM vms WHERE id = ANY($1) ORDER BY id"
    typealias Row = VMNameRow
    let ids: [UUID]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(ids)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> VMNameRow {
        let value = try row.decode((UUID, String).self)
        return VMNameRow(id: value.0, name: value.1)
    }
}

private struct InsertWorkloadRegistration: WorkloadRegistrationStatement {
    static let sql = """
        INSERT INTO workload_registrations (
            id, spiffe_id, kind, agent_name, service_account_id, organization_id,
            display_name, created_by, created_at, vm_id
        ) VALUES (
            $1, $2, $3::workload_registration_kind, $4, $5, $6, $7, $8,
            CURRENT_TIMESTAMP, $9
        )
        RETURNING \(workloadRegistrationColumns)
        """
    let write: WorkloadRegistrationWrite
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 9)
        bindings.append(write.id)
        bindings.append(write.spiffeID)
        bindings.append(write.kind)
        bindings.append(write.agentName)
        bindings.append(write.serviceAccountID)
        bindings.append(write.organizationID)
        bindings.append(write.displayName)
        bindings.append(write.createdBy)
        bindings.append(write.vmID)
        return bindings
    }
}

private struct InsertAgentRegistrationIfAbsent: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO workload_registrations (
            id, spiffe_id, kind, agent_name, created_at
        ) VALUES ($1, $2, 'agent', $3, CURRENT_TIMESTAMP)
        ON CONFLICT (spiffe_id) DO NOTHING
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let spiffeID: String
    let agentName: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(spiffeID)
        bindings.append(agentName)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.makeRandomAccess()["id"].decode(UUID.self)
    }
}

private struct DeleteWorkloadRegistration: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM workload_registrations
        WHERE id = $1 AND ($2::uuid IS NULL OR service_account_id = $2)
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let serviceAccountID: UUID?
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(serviceAccountID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteAgentRegistration: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM workload_registrations
        WHERE spiffe_id = $1 AND kind::text = 'agent'
        RETURNING id
        """
    typealias Row = UUID
    let spiffeID: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(spiffeID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteWorkloadRoleBindings: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM role_bindings
        WHERE principal_type::text = 'workload' AND principal_id = $1
        RETURNING id
        """
    typealias Row = UUID
    let principalID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(principalID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private func workloadConstraint(_ error: PSQLError, named name: String) -> Bool {
    error.serverInfo?[.sqlState] == "23505" && error.serverInfo?[.constraintName] == name
}

private struct ListObservedInterfaceAddresses: PostgresPreparedStatement {
    static let sql = """
        SELECT id, interface_id, family, address, prefix_length, created_at, updated_at
        FROM vm_interface_observed_addresses
        WHERE interface_id = ANY($1)
        ORDER BY interface_id, family, address, id
        """
    typealias Row = ObservedInterfaceAddressSnapshot
    let interfaceIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(interfaceIDs)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> ObservedInterfaceAddressSnapshot {
        let value = try row.decode((UUID, UUID, String, String, Int?, Date?, Date?).self)
        return ObservedInterfaceAddressSnapshot(
            id: value.0,
            interfaceID: value.1,
            family: value.2,
            address: value.3,
            prefixLength: value.4,
            createdAt: value.5,
            updatedAt: value.6)
    }
}

private struct InsertObservedInterfaceAddress: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO vm_interface_observed_addresses (
            id, interface_id, family, address, prefix_length, created_at, updated_at
        )
        VALUES ($1, $2, $3, $4, $5, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let interfaceID: UUID
    let address: ObservedInterfaceAddressWrite
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(interfaceID)
        bindings.append(address.family)
        bindings.append(address.address)
        bindings.append(address.prefixLength)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteObservedInterfaceAddresses: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM vm_interface_observed_addresses
        WHERE interface_id = ANY($1)
        RETURNING id
        """
    typealias Row = UUID
    let interfaceIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(interfaceIDs)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct FindWorkloadPrincipals: PostgresPreparedStatement {
    static let sql = """
        SELECT registration.id, registration.spiffe_id, registration.vm_id,
               vm.name, registration.display_name
        FROM workload_registrations AS registration
        LEFT JOIN vms AS vm ON vm.id = registration.vm_id
        WHERE registration.id = ANY($1) AND registration.kind = 'workload'
        ORDER BY registration.id
        """
    typealias Row = WorkloadPrincipalSnapshot
    let ids: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(ids)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> WorkloadPrincipalSnapshot {
        let value = try row.decode((UUID, String, UUID?, String?, String?).self)
        return WorkloadPrincipalSnapshot(
            id: value.0,
            spiffeID: value.1,
            vmID: value.2,
            vmName: value.3,
            displayName: value.4
        )
    }
}

private struct ListProjectVMPrincipals: PostgresPreparedStatement {
    static let sql = """
        SELECT vm.id, vm.name, registration.spiffe_id, registration.id, vm.created_at
        FROM vms AS vm
        LEFT JOIN workload_registrations AS registration ON registration.vm_id = vm.id
        WHERE vm.project_id = $1
        ORDER BY vm.created_at DESC, vm.id DESC
        """
    typealias Row = ProjectVMPrincipalSnapshot
    let projectID: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(projectID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> ProjectVMPrincipalSnapshot {
        let value = try row.decode((UUID, String, String?, UUID?, Date?).self)
        return ProjectVMPrincipalSnapshot(
            id: value.0,
            name: value.1,
            spiffeID: value.2,
            principalID: value.3,
            createdAt: value.4
        )
    }
}

private struct ListHeldWorkloadClaims: PostgresPreparedStatement {
    static let sql = """
        SELECT resource_kind::text, resource_id, reason, observed_status, first_seen_at
        FROM agent_workload_claims
        WHERE agent_id = $1 AND disposition::text = 'held'
        ORDER BY first_seen_at, id
        """
    typealias Row = HeldWorkloadClaimSnapshot
    let agentID: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(agentID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> HeldWorkloadClaimSnapshot {
        let value = try row.decode((String, UUID, String?, String?, Date?).self)
        return HeldWorkloadClaimSnapshot(
            resourceKind: value.0,
            resourceID: value.1,
            reason: value.2,
            observedStatus: value.3,
            firstSeenAt: value.4
        )
    }
}

private let workloadClaimColumns = """
    id, agent_id, resource_kind, resource_id, disposition,
    tombstone_generation, reason, observed_generation, observed_status,
    first_seen_at, last_seen_at
    """

private protocol WorkloadClaimStatement: PostgresPreparedStatement where Row == WorkloadClaimSnapshot {}

private extension WorkloadClaimStatement {
    func decodeRow(_ row: PostgresRow) throws -> WorkloadClaimSnapshot {
        let value = try row.decode(
            (UUID, String, String, UUID, String, Int64?, String?, Int64, String?, Date?, Date?).self)
        guard let disposition = WorkloadClaimDisposition(rawValue: value.4) else {
            throw WorkloadsPersistenceError.invalidClaimDisposition(value.4)
        }
        return WorkloadClaimSnapshot(
            id: value.0,
            agentID: value.1,
            resourceKind: value.2,
            resourceID: value.3,
            disposition: disposition,
            tombstoneGeneration: value.5,
            reason: value.6,
            observedGeneration: value.7,
            observedStatus: value.8,
            firstSeenAt: value.9,
            lastSeenAt: value.10)
    }
}

private struct ListWorkloadClaims: WorkloadClaimStatement {
    static let sql = """
        SELECT \(workloadClaimColumns)
        FROM agent_workload_claims
        WHERE agent_id = $1
        ORDER BY first_seen_at, id
        """
    let agentID: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(agentID)
        return bindings
    }
}

private struct ListWorkloadClaimsByDisposition: WorkloadClaimStatement {
    static let sql = """
        SELECT \(workloadClaimColumns)
        FROM agent_workload_claims
        WHERE agent_id = $1 AND disposition = $2
        ORDER BY first_seen_at, id
        """
    let agentID: String
    let disposition: WorkloadClaimDisposition
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(agentID)
        bindings.append(disposition.rawValue)
        return bindings
    }
}

private struct CountWorkloadClaims: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM agent_workload_claims WHERE agent_id = $1"
    typealias Row = Int
    let agentID: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(agentID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct InsertWorkloadClaims: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO agent_workload_claims (
            id, agent_id, resource_kind, resource_id, disposition,
            tombstone_generation, reason, observed_generation, observed_status,
            first_seen_at, last_seen_at
        )
        SELECT input.id, input."agentID", input."resourceKind", input."resourceID",
               input.disposition, input."tombstoneGeneration", input.reason,
               input."observedGeneration", input."observedStatus",
               CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM jsonb_to_recordset($1::jsonb) AS input(
            id uuid,
            "agentID" text,
            "resourceKind" text,
            "resourceID" uuid,
            disposition text,
            "tombstoneGeneration" bigint,
            reason text,
            "observedGeneration" bigint,
            "observedStatus" text
        )
        RETURNING id
        """
    typealias Row = UUID
    let payload: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(payload)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct UpdateWorkloadClaim: PostgresPreparedStatement {
    static let sql = """
        UPDATE agent_workload_claims
        SET disposition = $2, tombstone_generation = $3, reason = $4,
            observed_generation = $5, observed_status = $6,
            last_seen_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let disposition: WorkloadClaimDisposition
    let tombstoneGeneration: Int64?
    let reason: String?
    let observedGeneration: Int64
    let observedStatus: String?
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 6)
        bindings.append(id)
        bindings.append(disposition.rawValue)
        bindings.append(tombstoneGeneration)
        bindings.append(reason)
        bindings.append(observedGeneration)
        bindings.append(observedStatus)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteWorkloadClaims: PostgresPreparedStatement {
    static let sql = "DELETE FROM agent_workload_claims WHERE id = ANY($1) RETURNING id"
    typealias Row = UUID
    let ids: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(ids)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct LockAdoptableWorkloadClaims: WorkloadClaimStatement {
    static let sql = """
        SELECT \(workloadClaimColumns)
        FROM agent_workload_claims
        WHERE agent_id = $1 AND disposition = 'held' AND reason = $2
        ORDER BY first_seen_at, id
        FOR UPDATE
        """
    let targetAgentID: String
    let sourceReason: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(targetAgentID)
        bindings.append(sourceReason)
        return bindings
    }
}

private struct SourceWorkloadCounts: Sendable {
    let vms: Int
    let sandboxes: Int
}

private struct CountSourceWorkloads: PostgresPreparedStatement {
    static let sql = """
        SELECT
            (SELECT count(*)::bigint FROM vms WHERE hypervisor_id = $1),
            (SELECT count(*)::bigint FROM sandboxes WHERE hypervisor_id = $1)
        """
    typealias Row = SourceWorkloadCounts
    let sourceAgentID: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(sourceAgentID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> SourceWorkloadCounts {
        let value = try row.decode((Int, Int).self)
        return SourceWorkloadCounts(vms: value.0, sandboxes: value.1)
    }
}

private struct RepointVMs: PostgresPreparedStatement {
    static let sql = """
        UPDATE vms SET hypervisor_id = $2, updated_at = CURRENT_TIMESTAMP
        WHERE hypervisor_id = $1 AND id = ANY($3)
        RETURNING id
        """
    typealias Row = UUID
    let sourceAgentID: String
    let targetAgentID: String
    let ids: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(sourceAgentID); bindings.append(targetAgentID); bindings.append(ids)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct RepointSandboxes: PostgresPreparedStatement {
    static let sql = """
        UPDATE sandboxes SET hypervisor_id = $2, updated_at = CURRENT_TIMESTAMP
        WHERE hypervisor_id = $1 AND id = ANY($3)
        RETURNING id
        """
    typealias Row = UUID
    let sourceAgentID: String
    let targetAgentID: String
    let ids: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(sourceAgentID); bindings.append(targetAgentID); bindings.append(ids)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct MovableVolume: Sendable {
    let id: UUID
}

private struct FindMovableSourceVolumes: PostgresPreparedStatement {
    static let sql = """
        SELECT DISTINCT volume.id
        FROM volumes AS volume
        JOIN volume_replicas AS replica ON replica.volume_id = volume.id
        WHERE replica.agent_id = $1
          AND (volume.vm_id IS NULL OR volume.vm_id = ANY($2))
        ORDER BY volume.id
        """
    typealias Row = MovableVolume
    let sourceAgentID: String
    let claimedVMIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(sourceAgentID); bindings.append(claimedVMIDs)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> MovableVolume {
        MovableVolume(id: try row.decode(UUID.self))
    }
}

private struct RepointAttachedVolumes: PostgresPreparedStatement {
    static let sql = """
        UPDATE volumes
        SET attached_agent_id = CASE WHEN attached_agent_id = $1 THEN $2 ELSE attached_agent_id END,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = ANY($3)
        RETURNING id
        """
    typealias Row = UUID
    let sourceAgentID: String
    let targetAgentID: String
    let ids: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(sourceAgentID); bindings.append(targetAgentID); bindings.append(ids)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteRedundantSourceReplicas: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM volume_replicas AS source
        USING volume_replicas AS target
        WHERE source.agent_id = $1 AND target.agent_id = $2
          AND source.volume_id = target.volume_id
          AND source.volume_id = ANY($3)
        RETURNING source.volume_id
        """
    typealias Row = UUID
    let sourceAgentID: String
    let targetAgentID: String
    let volumeIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(sourceAgentID); bindings.append(targetAgentID); bindings.append(volumeIDs)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct RepointSourceReplicas: PostgresPreparedStatement {
    static let sql = """
        UPDATE volume_replicas SET agent_id = $2, updated_at = CURRENT_TIMESTAMP
        WHERE agent_id = $1 AND volume_id = ANY($3)
        RETURNING volume_id
        """
    typealias Row = UUID
    let sourceAgentID: String
    let targetAgentID: String
    let volumeIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(sourceAgentID); bindings.append(targetAgentID); bindings.append(volumeIDs)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}
