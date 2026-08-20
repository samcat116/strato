import Foundation
import PostgresNIO

public struct IAMOwnerReference: Equatable, Hashable, Sendable {
    public let type: String
    public let id: UUID

    public init(type: String, id: UUID) {
        self.type = type
        self.id = id
    }
}

public struct IAMNodeReference: Equatable, Hashable, Sendable {
    public let type: String
    public let id: UUID

    public init(type: String, id: UUID) {
        self.type = type
        self.id = id
    }
}

public struct IAMRoleSnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String?
    public let ownerType: String
    public let ownerID: UUID
    public let cedarText: String
    public let actions: [String]
    public let managed: Bool
    public let createdBy: UUID?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: UUID,
        name: String,
        description: String?,
        ownerType: String,
        ownerID: UUID,
        cedarText: String,
        actions: [String],
        managed: Bool,
        createdBy: UUID?,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.ownerType = ownerType
        self.ownerID = ownerID
        self.cedarText = cedarText
        self.actions = actions
        self.managed = managed
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct IAMPolicySnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String?
    public let ownerType: String
    public let ownerID: UUID
    public let cedarText: String
    public let effect: String
    public let enabled: Bool
    public let createdBy: UUID?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: UUID,
        name: String,
        description: String?,
        ownerType: String,
        ownerID: UUID,
        cedarText: String,
        effect: String,
        enabled: Bool,
        createdBy: UUID?,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.ownerType = ownerType
        self.ownerID = ownerID
        self.cedarText = cedarText
        self.effect = effect
        self.enabled = enabled
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct IAMGuardrailSnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String?
    public let nodeType: String
    public let nodeID: UUID
    public let effect: String
    public let actions: [String]
    public let principalMatchKind: String
    public let principalMatchID: UUID?
    public let resourceMatchKind: String
    public let resourceMatchValue: String?
    public let enabled: Bool
    public let createdBy: UUID?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let cedarText: String?
    public let authored: Bool

    public init(
        id: UUID,
        name: String,
        description: String?,
        nodeType: String,
        nodeID: UUID,
        effect: String,
        actions: [String],
        principalMatchKind: String,
        principalMatchID: UUID?,
        resourceMatchKind: String,
        resourceMatchValue: String?,
        enabled: Bool,
        createdBy: UUID?,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        cedarText: String?,
        authored: Bool
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.nodeType = nodeType
        self.nodeID = nodeID
        self.effect = effect
        self.actions = actions
        self.principalMatchKind = principalMatchKind
        self.principalMatchID = principalMatchID
        self.resourceMatchKind = resourceMatchKind
        self.resourceMatchValue = resourceMatchValue
        self.enabled = enabled
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cedarText = cedarText
        self.authored = authored
    }
}

public struct IAMRoleBindingSnapshot: Equatable, Sendable {
    public let id: UUID
    public let principalType: String
    public let principalID: UUID
    public let roleID: UUID
    public let nodeType: String
    public let nodeID: UUID
    public let condition: String?
    public let expiresAt: Date?
    public let createdBy: UUID?
    public let createdAt: Date?

    public init(
        id: UUID = UUID(),
        principalType: String,
        principalID: UUID,
        roleID: UUID,
        nodeType: String,
        nodeID: UUID,
        condition: String? = nil,
        expiresAt: Date? = nil,
        createdBy: UUID? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.principalType = principalType
        self.principalID = principalID
        self.roleID = roleID
        self.nodeType = nodeType
        self.nodeID = nodeID
        self.condition = condition
        self.expiresAt = expiresAt
        self.createdBy = createdBy
        self.createdAt = createdAt
    }
}

public struct IAMPolicySetVersionSnapshot: Equatable, Sendable {
    public let id: UUID
    public let version: Int
    public let reason: String
    public let changedBy: UUID?
    public let createdAt: Date?
}

public struct IAMUserAuthorizationFactsSnapshot: Equatable, Sendable {
    public let id: UUID
    public let isSystemAdmin: Bool
    public let groupIDs: [UUID]
    public let organizationIDs: [UUID]
}

public enum IAMPersistenceError: Error, Equatable, Sendable {
    case duplicateRoleName(ownerType: String, ownerID: UUID, name: String)
    case duplicatePolicyName(ownerType: String, ownerID: UUID, name: String)
    case duplicateGuardrailName(nodeType: String, nodeID: UUID, name: String)
    case duplicateBinding
    case policyVersionCollision
    case unexpectedRowCount(expected: Int, actual: Int)
    case unsupportedMembershipNodeType(String)
    case membershipNodeNotFound(IAMNodeReference)
}

/// Owns IAM policy-set rows and role grants. Its operations speak in policy
/// intent and immutable facts; SQL mechanics and retryable version allocation
/// remain inside the module.
public struct IAMPersistence: Sendable {
    private static let policyTransactionAttempts = 5
    private let database: PostgresDatabase
    private let resourceTree: ResourceTreePersistence

    init(database: PostgresDatabase) {
        self.database = database
        self.resourceTree = ResourceTreePersistence(database: database)
    }

    /// Resolve one parent edge for every requested IAM node. Keeping this
    /// operation on the IAM module lets authorization callers depend on one
    /// cohesive capability instead of acquiring a second persistence service.
    public func resourceTreeSteps(
        nodeType: String,
        ids: [UUID]
    ) async throws -> [UUID: ResourceTreeStepSnapshot] {
        try await resourceTree.steps(nodeType: nodeType, ids: ids)
    }

    public func userAuthorizationFacts(
        ids: [UUID]
    ) async throws -> [IAMUserAuthorizationFactsSnapshot] {
        guard !ids.isEmpty else { return [] }
        return try await database.withSession(operation: "iam.authorization.user_facts") { session in
            try await session.execute(
                ResolveIAMUserAuthorizationFacts(ids: Array(Set(ids))),
                operation: "iam.authorization.user_facts.query"
            )
        }
    }

    /// Whether a principal is outside an organization's tenancy boundary.
    /// Missing or malformed principal kinds fail closed as external.
    public func principalIsExternal(
        type: String,
        id: UUID,
        organizationID: UUID
    ) async throws -> Bool {
        try await database.withSession(operation: "iam.principals.external") { session in
            let rows: [Bool]
            switch type {
            case "user":
                rows = try await session.execute(
                    IsExternalUser(id: id, organizationID: organizationID),
                    operation: "iam.principals.external.user"
                )
            case "group":
                rows = try await session.execute(
                    IsExternalGroup(id: id, organizationID: organizationID),
                    operation: "iam.principals.external.group"
                )
            case "service_account":
                rows = try await session.execute(
                    IsExternalServiceAccount(id: id, organizationID: organizationID),
                    operation: "iam.principals.external.service_account"
                )
            case "workload":
                rows = try await session.execute(
                    IsExternalWorkload(id: id, organizationID: organizationID),
                    operation: "iam.principals.external.workload"
                )
            default:
                return true
            }
            return try only(rows)
        }
    }

    public func policyOwnerExists(type: String, id: UUID) async throws -> Bool {
        try await database.withSession(operation: "iam.policy_owner.exists") { session in
            try only(
                await session.execute(
                    IAMPolicyOwnerExists(type: type, id: id),
                    operation: "iam.policy_owner.exists.query"
                )
            )
        }
    }

    /// Whether each known agent currently hosts any VM, sandbox, or
    /// authoritative volume replica belonging to a different root
    /// organization. Unknown agent ids are absent so callers can fail closed.
    public func agentsHostingForeignWorkloads(
        ids: [UUID]
    ) async throws -> [UUID: Bool] {
        guard !ids.isEmpty else { return [:] }
        return try await database.withSession(operation: "iam.authorization.agent_foreign_workloads") {
            session in
            let rows = try await session.execute(
                ResolveAgentForeignWorkloads(ids: Array(Set(ids))),
                operation: "iam.authorization.agent_foreign_workloads.query"
            )
            return Dictionary(uniqueKeysWithValues: rows)
        }
    }

    public func role(id: UUID) async throws -> IAMRoleSnapshot? {
        try await database.withSession(operation: "iam.roles.lookup") { session in
            try oneOrNone(await session.execute(FindIAMRole(id: id), operation: "iam.roles.lookup.query"))
        }
    }

    public func roles(ids: [UUID]) async throws -> [IAMRoleSnapshot] {
        guard !ids.isEmpty else { return [] }
        return try await database.withSession(operation: "iam.roles.lookup_many") { session in
            try await session.execute(FindIAMRoles(ids: ids), operation: "iam.roles.lookup_many.query")
        }
    }

    public func allRoles() async throws -> [IAMRoleSnapshot] {
        try await database.withSession(operation: "iam.roles.list_all") { session in
            try await session.execute(ListIAMRoles(), operation: "iam.roles.list_all.query")
        }
    }

    public func roles(ownedBy owner: IAMOwnerReference) async throws -> [IAMRoleSnapshot] {
        try await database.withSession(operation: "iam.roles.list_owned") { session in
            try await session.execute(
                ListOwnedIAMRoles(owner: owner),
                operation: "iam.roles.list_owned.query"
            )
        }
    }

    public func bindableRoles(owners: [IAMOwnerReference]) async throws -> [IAMRoleSnapshot] {
        let ownerTypes = owners.map(\.type)
        let ownerIDs = owners.map(\.id)
        return try await database.withSession(operation: "iam.roles.list_bindable") { session in
            try await session.execute(
                ListBindableIAMRoles(ownerTypes: ownerTypes, ownerIDs: ownerIDs),
                operation: "iam.roles.list_bindable.query"
            )
        }
    }

    public func activeBindingCount(roleID: UUID, at now: Date = Date()) async throws -> Int {
        try await database.withSession(operation: "iam.roles.active_binding_count") { session in
            try only(
                await session.execute(
                    CountActiveRoleBindings(roleID: roleID, now: now),
                    operation: "iam.roles.active_binding_count.query"
                )
            )
        }
    }

    public func activeBindings(
        subjects: [IAMOwnerReference],
        nodes: [IAMNodeReference],
        at now: Date = Date()
    ) async throws -> [IAMRoleBindingSnapshot] {
        guard !subjects.isEmpty, !nodes.isEmpty else { return [] }
        return try await database.withSession(operation: "iam.bindings.list_active") { session in
            try await session.execute(
                ListActiveIAMBindings(
                    principalTypes: subjects.map(\.type),
                    principalIDs: subjects.map(\.id),
                    nodeTypes: nodes.map(\.type),
                    nodeIDs: nodes.map(\.id),
                    now: now
                ),
                operation: "iam.bindings.list_active.query"
            )
        }
    }

    public func activeBindings(
        subject: IAMOwnerReference,
        node: IAMNodeReference,
        at now: Date = Date()
    ) async throws -> [IAMRoleBindingSnapshot] {
        try await activeBindings(subjects: [subject], nodes: [node], at: now)
    }

    public func bindings(at nodes: [IAMNodeReference], at now: Date = Date()) async throws
        -> [IAMRoleBindingSnapshot]
    {
        guard !nodes.isEmpty else { return [] }
        return try await database.withSession(operation: "iam.bindings.list_at_nodes") { session in
            try await session.execute(
                ListIAMBindingsAtNodes(
                    nodeTypes: nodes.map(\.type),
                    nodeIDs: nodes.map(\.id),
                    now: now
                ),
                operation: "iam.bindings.list_at_nodes.query"
            )
        }
    }

    public func grant(_ binding: IAMRoleBindingSnapshot) async throws -> IAMRoleBindingSnapshot {
        do {
            return try await database.withSession(operation: "iam.bindings.grant") { session in
                try only(
                    await session.execute(
                        InsertIAMBinding(binding: binding),
                        operation: "iam.bindings.grant.query"
                    )
                )
            }
        } catch let error as PSQLError
            where isConstraint(error, named: "uq_role_bindings_principal_role_node")
        {
            throw IAMPersistenceError.duplicateBinding
        }
    }

    /// Idempotently establish a grant. A concurrent writer that inserts the
    /// same logical grant is adopted and the requested expiry wins, matching
    /// the historical membership and resource-creation behavior.
    public func ensureGrant(_ binding: IAMRoleBindingSnapshot) async throws -> IAMRoleBindingSnapshot {
        try await database.withSession(operation: "iam.bindings.ensure") { session in
            try only(
                await session.execute(
                    UpsertIAMBinding(binding: binding),
                    operation: "iam.bindings.ensure.query"
                )
            )
        }
    }

    public func revoke(
        subject: IAMOwnerReference,
        roleID: UUID,
        node: IAMNodeReference
    ) async throws -> [UUID] {
        try await database.withSession(operation: "iam.bindings.revoke") { session in
            try await session.execute(
                DeleteIAMBinding(subject: subject, roleID: roleID, node: node),
                operation: "iam.bindings.revoke.query"
            )
        }
    }

    public func revoke(
        subject: IAMOwnerReference,
        node: IAMNodeReference
    ) async throws -> [UUID] {
        try await database.withSession(operation: "iam.bindings.revoke_at_node") { session in
            try await session.execute(
                DeleteIAMBindingsForSubjectAtNode(subject: subject, node: node),
                operation: "iam.bindings.revoke_at_node.query"
            )
        }
    }

    public func activeBindings(
        forSubject subject: IAMOwnerReference,
        at now: Date = Date()
    ) async throws -> [IAMRoleBindingSnapshot] {
        try await database.withSession(operation: "iam.bindings.list_active_subject") { session in
            try await session.execute(
                ListActiveIAMBindingsForSubject(subject: subject, now: now),
                operation: "iam.bindings.list_active_subject.query"
            )
        }
    }

    public func activeBindings(
        forSubjects subjects: [IAMOwnerReference],
        at now: Date = Date()
    ) async throws -> [IAMRoleBindingSnapshot] {
        guard !subjects.isEmpty else { return [] }
        return try await database.withSession(operation: "iam.bindings.list_active_subjects") {
            session in
            try await session.execute(
                ListActiveIAMBindingsForSubjects(subjects: subjects, now: now),
                operation: "iam.bindings.list_active_subjects.query"
            )
        }
    }

    public func allBindings(
        forSubject subject: IAMOwnerReference
    ) async throws -> [IAMRoleBindingSnapshot] {
        try await database.withSession(operation: "iam.bindings.list_subject") { session in
            try await session.execute(
                ListIAMBindingsForSubject(subject: subject),
                operation: "iam.bindings.list_subject.query"
            )
        }
    }

    public func allActiveBindings(
        at now: Date = Date()
    ) async throws -> [IAMRoleBindingSnapshot] {
        try await database.withSession(operation: "iam.bindings.list_all_active") { session in
            try await session.execute(
                ListAllActiveIAMBindings(now: now),
                operation: "iam.bindings.list_all_active.query"
            )
        }
    }

    /// Serialize an exclusive membership mutation with a row lock on its
    /// organization, folder, or project, and keep the complete read-modify-
    /// write sequence on the pinned transaction connection.
    public func withMembershipNodeLocked<Result: Sendable>(
        node: IAMNodeReference,
        _ body: @escaping @Sendable (IAMBindingTransaction) async throws -> Result
    ) async throws -> Result {
        try await database.withTransaction(operation: "iam.bindings.membership_change") { session in
            let locked: [UUID]
            switch node.type {
            case "organization":
                locked = try await session.execute(
                    LockIAMOrganization(id: node.id), operation: "iam.bindings.lock_organization")
            case "organizational_unit":
                locked = try await session.execute(
                    LockIAMOrganizationalUnit(id: node.id), operation: "iam.bindings.lock_folder")
            case "project":
                locked = try await session.execute(
                    LockIAMProject(id: node.id), operation: "iam.bindings.lock_project")
            default:
                throw IAMPersistenceError.unsupportedMembershipNodeType(node.type)
            }
            guard locked.count == 1 else {
                throw IAMPersistenceError.membershipNodeNotFound(node)
            }
            return try await body(IAMBindingTransaction(session: session))
        }
    }

    public func revokeAll(forSubjects subjects: [IAMOwnerReference]) async throws -> [UUID] {
        guard !subjects.isEmpty else { return [] }
        return try await database.withSession(operation: "iam.bindings.revoke_subjects") { session in
            try await session.execute(
                DeleteIAMBindingsForSubjects(
                    principalTypes: subjects.map(\.type),
                    principalIDs: subjects.map(\.id)
                ),
                operation: "iam.bindings.revoke_subjects.query"
            )
        }
    }

    public func revokeAll(atNodes nodes: [IAMNodeReference]) async throws -> [UUID] {
        guard !nodes.isEmpty else { return [] }
        return try await database.withSession(operation: "iam.bindings.revoke_nodes") { session in
            try await session.execute(
                DeleteIAMBindingsAtNodes(nodeTypes: nodes.map(\.type), nodeIDs: nodes.map(\.id)),
                operation: "iam.bindings.revoke_nodes.query"
            )
        }
    }

    public func policy(id: UUID) async throws -> IAMPolicySnapshot? {
        try await database.withSession(operation: "iam.policies.lookup") { session in
            try oneOrNone(await session.execute(FindIAMPolicy(id: id), operation: "iam.policies.lookup.query"))
        }
    }

    public func policies(ownedBy owner: IAMOwnerReference) async throws -> [IAMPolicySnapshot] {
        try await database.withSession(operation: "iam.policies.list_owned") { session in
            try await session.execute(
                ListOwnedIAMPolicies(owner: owner),
                operation: "iam.policies.list_owned.query"
            )
        }
    }

    public func enabledPolicies(owners: [IAMOwnerReference]) async throws -> [IAMPolicySnapshot] {
        guard !owners.isEmpty else { return [] }
        return try await database.withSession(operation: "iam.policies.list_enabled") { session in
            try await session.execute(
                ListEnabledIAMPolicies(ownerTypes: owners.map(\.type), ownerIDs: owners.map(\.id)),
                operation: "iam.policies.list_enabled.query"
            )
        }
    }

    public func allEnabledPolicies() async throws -> [IAMPolicySnapshot] {
        try await database.withSession(operation: "iam.policies.list_all_enabled") { session in
            try await session.execute(
                ListAllEnabledIAMPolicies(),
                operation: "iam.policies.list_all_enabled.query"
            )
        }
    }

    public func guardrail(id: UUID) async throws -> IAMGuardrailSnapshot? {
        try await database.withSession(operation: "iam.guardrails.lookup") { session in
            try oneOrNone(
                await session.execute(FindIAMGuardrail(id: id), operation: "iam.guardrails.lookup.query")
            )
        }
    }

    public func guardrails(attachedTo node: IAMNodeReference) async throws -> [IAMGuardrailSnapshot] {
        try await database.withSession(operation: "iam.guardrails.list_attached") { session in
            try await session.execute(
                ListAttachedIAMGuardrails(node: node),
                operation: "iam.guardrails.list_attached.query"
            )
        }
    }

    public func enabledGuardrails(along nodes: [IAMNodeReference]) async throws -> [IAMGuardrailSnapshot] {
        guard !nodes.isEmpty else { return [] }
        return try await database.withSession(operation: "iam.guardrails.list_enabled") { session in
            try await session.execute(
                ListEnabledIAMGuardrails(nodeTypes: nodes.map(\.type), nodeIDs: nodes.map(\.id)),
                operation: "iam.guardrails.list_enabled.query"
            )
        }
    }

    public func allEnabledGuardrails() async throws -> [IAMGuardrailSnapshot] {
        try await database.withSession(operation: "iam.guardrails.list_all_enabled") { session in
            try await session.execute(
                ListAllEnabledIAMGuardrails(),
                operation: "iam.guardrails.list_all_enabled.query"
            )
        }
    }

    public func guardrailsMissingCedarText() async throws -> [IAMGuardrailSnapshot] {
        try await database.withSession(operation: "iam.guardrails.list_missing_cedar") { session in
            try await session.execute(
                ListIAMGuardrailsMissingCedarText(),
                operation: "iam.guardrails.list_missing_cedar.query"
            )
        }
    }

    @discardableResult
    public func backfillGuardrailCedarText(id: UUID, cedarText: String) async throws -> Bool {
        try await database.withSession(operation: "iam.guardrails.backfill_cedar") { session in
            try await session.execute(
                BackfillIAMGuardrailCedarText(id: id, cedarText: cedarText),
                operation: "iam.guardrails.backfill_cedar.query"
            ).count == 1
        }
    }

    public func currentPolicySetVersion() async throws -> Int {
        try await database.withSession(operation: "iam.policy_set.current_version") { session in
            try only(
                await session.execute(
                    CurrentPolicySetVersion(),
                    operation: "iam.policy_set.current_version.query"
                )
            )
        }
    }

    public func latestPolicySetVersion() async throws -> IAMPolicySetVersionSnapshot? {
        try await database.withSession(operation: "iam.policy_set.latest") { session in
            try oneOrNone(
                await session.execute(LatestPolicySetVersion(), operation: "iam.policy_set.latest.query")
            )
        }
    }

    /// Policy rows and their version ledger entry commit together. The only
    /// retry is the existing max-plus-one uniqueness collision, replayed from
    /// the transaction boundary on a fresh connection lease.
    public func withPolicySetChange<Result: Sendable>(
        _ body: @escaping @Sendable (IAMPolicySetTransaction) async throws -> Result
    ) async throws -> Result {
        for attempt in 1...Self.policyTransactionAttempts {
            do {
                return try await database.withTransaction(operation: "iam.policy_set.change") { session in
                    try await body(IAMPolicySetTransaction(session: session))
                }
            } catch let error as PSQLError {
                let collision =
                    error.serverInfo?[.sqlState] == "23505"
                    && error.serverInfo?[.constraintName] == "uq:iam_policy_set_versions.version"
                guard collision else { throw error }
                guard attempt < Self.policyTransactionAttempts else {
                    throw IAMPersistenceError.policyVersionCollision
                }
            }
        }
        throw IAMPersistenceError.policyVersionCollision
    }

    private func oneOrNone<Value>(_ rows: [Value]) throws -> Value? {
        guard rows.count <= 1 else {
            throw IAMPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first
    }

    private func only<Value>(_ rows: [Value]) throws -> Value {
        guard rows.count == 1, let value = rows.first else {
            throw IAMPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return value
    }
}

public struct IAMPolicySetTransaction: Sendable {
    private let session: PostgresSession

    fileprivate init(session: PostgresSession) {
        self.session = session
    }

    public func role(id: UUID) async throws -> IAMRoleSnapshot? {
        try oneOrNone(await session.execute(FindIAMRole(id: id), operation: "iam.tx.roles.lookup"))
    }

    public func allRoles() async throws -> [IAMRoleSnapshot] {
        try await session.execute(ListIAMRoles(), operation: "iam.tx.roles.list_all")
    }

    public func createRole(_ role: IAMRoleSnapshot) async throws -> IAMRoleSnapshot {
        do {
            return try only(await session.execute(InsertIAMRole(role: role), operation: "iam.tx.roles.create"))
        } catch let error as PSQLError where isConstraint(error, named: "uq:iam_roles.owner_type+iam_roles.owner_id+iam_roles.name") {
            throw IAMPersistenceError.duplicateRoleName(
                ownerType: role.ownerType,
                ownerID: role.ownerID,
                name: role.name
            )
        }
    }

    public func replaceRole(_ role: IAMRoleSnapshot) async throws -> IAMRoleSnapshot? {
        do {
            return try oneOrNone(
                await session.execute(ReplaceIAMRole(role: role), operation: "iam.tx.roles.replace")
            )
        } catch let error as PSQLError where isConstraint(error, named: "uq:iam_roles.owner_type+iam_roles.owner_id+iam_roles.name") {
            throw IAMPersistenceError.duplicateRoleName(
                ownerType: role.ownerType,
                ownerID: role.ownerID,
                name: role.name
            )
        }
    }

    public func reconcileManagedRole(_ role: IAMRoleSnapshot) async throws -> IAMRoleSnapshot {
        try only(
            await session.execute(
                UpsertManagedIAMRole(role: role),
                operation: "iam.tx.roles.reconcile_managed"
            )
        )
    }

    public func deleteRole(id: UUID) async throws -> Bool {
        try await session.execute(DeleteIAMRole(id: id), operation: "iam.tx.roles.delete").count == 1
    }

    public func deleteRoles(ownedBy owner: IAMOwnerReference) async throws -> Int {
        try await session.execute(
            DeleteOwnedIAMRoles(owner: owner),
            operation: "iam.tx.roles.delete_owned"
        ).count
    }

    public func policy(id: UUID) async throws -> IAMPolicySnapshot? {
        try oneOrNone(await session.execute(FindIAMPolicy(id: id), operation: "iam.tx.policies.lookup"))
    }

    public func createPolicy(_ policy: IAMPolicySnapshot) async throws -> IAMPolicySnapshot {
        do {
            return try only(
                await session.execute(InsertIAMPolicy(policy: policy), operation: "iam.tx.policies.create")
            )
        } catch let error as PSQLError where isConstraint(error, named: "uq:iam_policies.owner_type+iam_policies.owner_id+iam_policies.n") {
            throw IAMPersistenceError.duplicatePolicyName(
                ownerType: policy.ownerType,
                ownerID: policy.ownerID,
                name: policy.name
            )
        }
    }

    public func replacePolicy(_ policy: IAMPolicySnapshot) async throws -> IAMPolicySnapshot? {
        do {
            return try oneOrNone(
                await session.execute(ReplaceIAMPolicy(policy: policy), operation: "iam.tx.policies.replace")
            )
        } catch let error as PSQLError where isConstraint(error, named: "uq:iam_policies.owner_type+iam_policies.owner_id+iam_policies.n") {
            throw IAMPersistenceError.duplicatePolicyName(
                ownerType: policy.ownerType,
                ownerID: policy.ownerID,
                name: policy.name
            )
        }
    }

    public func deletePolicy(id: UUID) async throws -> Bool {
        try await session.execute(DeleteIAMPolicy(id: id), operation: "iam.tx.policies.delete").count == 1
    }

    public func deletePolicies(ownedBy owner: IAMOwnerReference) async throws -> Int {
        try await session.execute(
            DeleteOwnedIAMPolicies(owner: owner),
            operation: "iam.tx.policies.delete_owned"
        ).count
    }

    public func guardrail(id: UUID) async throws -> IAMGuardrailSnapshot? {
        try oneOrNone(
            await session.execute(FindIAMGuardrail(id: id), operation: "iam.tx.guardrails.lookup")
        )
    }

    public func createGuardrail(_ guardrail: IAMGuardrailSnapshot) async throws -> IAMGuardrailSnapshot {
        do {
            return try only(
                await session.execute(
                    InsertIAMGuardrail(guardrail: guardrail),
                    operation: "iam.tx.guardrails.create"
                )
            )
        } catch let error as PSQLError where isConstraint(error, named: "uq:iam_guardrails.node_type+iam_guardrails.node_id+iam_guardrai") {
            throw IAMPersistenceError.duplicateGuardrailName(
                nodeType: guardrail.nodeType,
                nodeID: guardrail.nodeID,
                name: guardrail.name
            )
        }
    }

    public func replaceGuardrail(_ guardrail: IAMGuardrailSnapshot) async throws -> IAMGuardrailSnapshot? {
        do {
            return try oneOrNone(
                await session.execute(
                    ReplaceIAMGuardrail(guardrail: guardrail),
                    operation: "iam.tx.guardrails.replace"
                )
            )
        } catch let error as PSQLError where isConstraint(error, named: "uq:iam_guardrails.node_type+iam_guardrails.node_id+iam_guardrai") {
            throw IAMPersistenceError.duplicateGuardrailName(
                nodeType: guardrail.nodeType,
                nodeID: guardrail.nodeID,
                name: guardrail.name
            )
        }
    }

    public func deleteGuardrail(id: UUID) async throws -> Bool {
        try await session.execute(DeleteIAMGuardrail(id: id), operation: "iam.tx.guardrails.delete").count == 1
    }

    public func grant(_ binding: IAMRoleBindingSnapshot) async throws -> IAMRoleBindingSnapshot {
        do {
            return try only(
                await session.execute(InsertIAMBinding(binding: binding), operation: "iam.tx.bindings.grant")
            )
        } catch let error as PSQLError
            where isConstraint(error, named: "uq_role_bindings_principal_role_node")
        {
            throw IAMPersistenceError.duplicateBinding
        }
    }

    public func revoke(
        subject: IAMOwnerReference,
        roleID: UUID,
        node: IAMNodeReference
    ) async throws -> [UUID] {
        try await session.execute(
            DeleteIAMBinding(subject: subject, roleID: roleID, node: node),
            operation: "iam.tx.bindings.revoke"
        )
    }

    public func revokeAll(forSubjects subjects: [IAMOwnerReference]) async throws -> [UUID] {
        guard !subjects.isEmpty else { return [] }
        return try await session.execute(
            DeleteIAMBindingsForSubjects(
                principalTypes: subjects.map(\.type),
                principalIDs: subjects.map(\.id)
            ),
            operation: "iam.tx.bindings.revoke_subjects"
        )
    }

    public func revokeAll(atNodes nodes: [IAMNodeReference]) async throws -> [UUID] {
        guard !nodes.isEmpty else { return [] }
        return try await session.execute(
            DeleteIAMBindingsAtNodes(nodeTypes: nodes.map(\.type), nodeIDs: nodes.map(\.id)),
            operation: "iam.tx.bindings.revoke_nodes"
        )
    }

    public func currentPolicySetVersion() async throws -> Int {
        try only(
            await session.execute(CurrentPolicySetVersion(), operation: "iam.tx.policy_set.current_version")
        )
    }

    @discardableResult
    public func bumpPolicySetVersion(reason: String, changedBy: UUID? = nil) async throws -> Int {
        let next = try await currentPolicySetVersion() + 1
        return try only(
            await session.execute(
                InsertPolicySetVersion(
                    id: UUID(),
                    version: next,
                    reason: reason,
                    changedBy: changedBy
                ),
                operation: "iam.tx.policy_set.bump"
            )
        )
    }

    private func oneOrNone<Value>(_ rows: [Value]) throws -> Value? {
        guard rows.count <= 1 else {
            throw IAMPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first
    }

    private func only<Value>(_ rows: [Value]) throws -> Value {
        guard rows.count == 1, let value = rows.first else {
            throw IAMPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return value
    }
}

public struct IAMBindingTransaction: Sendable {
    private let session: PostgresSession

    fileprivate init(session: PostgresSession) {
        self.session = session
    }

    public func activeBindings(
        subject: IAMOwnerReference,
        node: IAMNodeReference,
        at now: Date = Date()
    ) async throws -> [IAMRoleBindingSnapshot] {
        try await session.execute(
            ListActiveIAMBindings(
                principalTypes: [subject.type],
                principalIDs: [subject.id],
                nodeTypes: [node.type],
                nodeIDs: [node.id],
                now: now
            ),
            operation: "iam.tx.bindings.list_active"
        )
    }

    public func ensureGrant(_ binding: IAMRoleBindingSnapshot) async throws -> IAMRoleBindingSnapshot {
        try only(
            await session.execute(
                UpsertIAMBinding(binding: binding),
                operation: "iam.tx.bindings.ensure"
            )
        )
    }

    public func revoke(
        subject: IAMOwnerReference,
        roleID: UUID,
        node: IAMNodeReference
    ) async throws -> [UUID] {
        try await session.execute(
            DeleteIAMBinding(subject: subject, roleID: roleID, node: node),
            operation: "iam.tx.bindings.revoke"
        )
    }

    public func revoke(
        subject: IAMOwnerReference,
        node: IAMNodeReference
    ) async throws -> [UUID] {
        try await session.execute(
            DeleteIAMBindingsForSubjectAtNode(subject: subject, node: node),
            operation: "iam.tx.bindings.revoke_at_node"
        )
    }

    private func only<Value>(_ rows: [Value]) throws -> Value {
        guard rows.count == 1, let value = rows.first else {
            throw IAMPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return value
    }
}

private func isConstraint(_ error: PSQLError, named name: String) -> Bool {
    error.serverInfo?[.sqlState] == "23505" && error.serverInfo?[.constraintName] == name
}

private struct ResolveIAMUserAuthorizationFacts: PostgresPreparedStatement {
    static let sql = """
        SELECT users.id,
               users.is_system_admin,
               COALESCE(
                 array_agg(DISTINCT user_groups.group_id)
                   FILTER (WHERE user_groups.group_id IS NOT NULL),
                 ARRAY[]::uuid[]
               ) AS group_ids,
               COALESCE(
                 array_agg(DISTINCT user_organizations.organization_id)
                   FILTER (WHERE user_organizations.organization_id IS NOT NULL),
                 ARRAY[]::uuid[]
               ) AS organization_ids
        FROM users
        LEFT JOIN user_groups ON user_groups.user_id = users.id
        LEFT JOIN user_organizations ON user_organizations.user_id = users.id
        WHERE users.id = ANY($1::uuid[])
        GROUP BY users.id, users.is_system_admin
        ORDER BY users.id
        """
    typealias Row = IAMUserAuthorizationFactsSnapshot
    let ids: [UUID]
    func makeBindings() throws -> PostgresBindings { try arrayBindings(ids) }
    func decodeRow(_ row: PostgresRow) throws -> IAMUserAuthorizationFactsSnapshot {
        let value = try row.decode((UUID, Bool, [UUID], [UUID]).self)
        return IAMUserAuthorizationFactsSnapshot(
            id: value.0,
            isSystemAdmin: value.1,
            groupIDs: value.2,
            organizationIDs: value.3
        )
    }
}

private struct ResolveAgentForeignWorkloads: PostgresPreparedStatement {
    static let sql = """
        WITH agent_roots AS (
            SELECT agents.id,
                   COALESCE(agents.organization_id, agent_ous.organization_id) AS organization_id
            FROM agents
            LEFT JOIN organizational_units AS agent_ous
              ON agent_ous.id = agents.organizational_unit_id
            WHERE agents.id = ANY($1::uuid[])
        ), hosted_projects AS (
            SELECT agent_roots.id AS agent_id, vms.project_id
            FROM agent_roots
            JOIN vms ON vms.hypervisor_id = agent_roots.id::text
            UNION
            SELECT agent_roots.id, sandboxes.project_id
            FROM agent_roots
            JOIN sandboxes ON sandboxes.hypervisor_id = agent_roots.id::text
            UNION
            SELECT agent_roots.id, volumes.project_id
            FROM agent_roots
            JOIN volume_replicas
              ON volume_replicas.agent_id = agent_roots.id::text
             AND volume_replicas.state IN ('healthy', 'provisioning')
            JOIN volumes ON volumes.id = volume_replicas.volume_id
        ), hosted_roots AS (
            SELECT hosted_projects.agent_id,
                   COALESCE(projects.organization_id, project_ous.organization_id) AS organization_id
            FROM hosted_projects
            JOIN projects ON projects.id = hosted_projects.project_id
            LEFT JOIN organizational_units AS project_ous
              ON project_ous.id = projects.organizational_unit_id
        )
        SELECT agent_roots.id,
               EXISTS (
                 SELECT 1
                 FROM hosted_roots
                 WHERE hosted_roots.agent_id = agent_roots.id
                   AND hosted_roots.organization_id
                       IS DISTINCT FROM agent_roots.organization_id
               ) AS hosts_foreign_workloads
        FROM agent_roots
        ORDER BY agent_roots.id
        """
    typealias Row = (UUID, Bool)
    let ids: [UUID]
    func makeBindings() throws -> PostgresBindings { try arrayBindings(ids) }
    func decodeRow(_ row: PostgresRow) throws -> Row {
        try row.decode(Row.self)
    }
}

private let iamRoleColumns = "id, name, description, owner_type, owner_id, cedar_text, actions, managed, created_by, created_at, updated_at"
private let iamPolicyColumns = "id, name, description, owner_type, owner_id, cedar_text, effect, enabled, created_by, created_at, updated_at"
private let iamGuardrailColumns = "id, name, description, node_type, node_id, effect, actions, principal_match_kind, principal_match_id, resource_match_kind, resource_match_value, enabled, created_by, created_at, updated_at, cedar_text, authored"
private let iamBindingColumns = "id, principal_type, principal_id, role_id, node_type, node_id, condition, expires_at, created_by, created_at"
private let policySetVersionColumns = "id, version, reason, changed_by, created_at"

private protocol IAMRoleStatement: PostgresPreparedStatement where Row == IAMRoleSnapshot {}
private extension IAMRoleStatement {
    func decodeRow(_ row: PostgresRow) throws -> IAMRoleSnapshot {
        let value = try row.decode((UUID, String, String?, String, UUID, String, [String], Bool, UUID?, Date?, Date?).self)
        return IAMRoleSnapshot(
            id: value.0,
            name: value.1,
            description: value.2,
            ownerType: value.3,
            ownerID: value.4,
            cedarText: value.5,
            actions: value.6,
            managed: value.7,
            createdBy: value.8,
            createdAt: value.9,
            updatedAt: value.10
        )
    }
}

private struct FindIAMRole: IAMRoleStatement {
    static let sql = "SELECT \(iamRoleColumns) FROM iam_roles WHERE id = $1 LIMIT 1"
    let id: UUID
    func makeBindings() -> PostgresBindings { bindings(id) }
}

private struct FindIAMRoles: IAMRoleStatement {
    static let sql = "SELECT \(iamRoleColumns) FROM iam_roles WHERE id = ANY($1) ORDER BY id"
    let ids: [UUID]
    func makeBindings() throws -> PostgresBindings { try arrayBindings(ids) }
}

private struct ListIAMRoles: IAMRoleStatement {
    static let sql = "SELECT \(iamRoleColumns) FROM iam_roles ORDER BY name, id"
    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct ListOwnedIAMRoles: IAMRoleStatement {
    static let sql = "SELECT \(iamRoleColumns) FROM iam_roles WHERE owner_type = $1 AND owner_id = $2 ORDER BY name, id"
    let owner: IAMOwnerReference
    func makeBindings() -> PostgresBindings { bindings(owner.type, owner.id) }
}

private struct ListBindableIAMRoles: IAMRoleStatement {
    static let sql = """
        SELECT \(iamRoleColumns)
        FROM iam_roles
        WHERE owner_type = 'platform'
           OR (owner_type, owner_id) IN (
                SELECT input.owner_type, input.owner_id
                FROM unnest($1::text[], $2::uuid[]) AS input(owner_type, owner_id)
           )
        ORDER BY name, id
        """
    let ownerTypes: [String]
    let ownerIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var result = PostgresBindings(capacity: 2)
        result.append(ownerTypes)
        result.append(ownerIDs)
        return result
    }
}

private struct InsertIAMRole: IAMRoleStatement {
    static let sql = """
        INSERT INTO iam_roles (
            id, name, description, owner_type, owner_id, cedar_text, actions,
            managed, created_by, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING \(iamRoleColumns)
        """
    let role: IAMRoleSnapshot
    func makeBindings() throws -> PostgresBindings {
        var result = PostgresBindings(capacity: 9)
        result.append(role.id)
        result.append(role.name)
        result.append(role.description)
        result.append(role.ownerType)
        result.append(role.ownerID)
        result.append(role.cedarText)
        result.append(role.actions)
        result.append(role.managed)
        result.append(role.createdBy)
        return result
    }
}

private struct ReplaceIAMRole: IAMRoleStatement {
    static let sql = """
        UPDATE iam_roles
        SET name = $2, description = $3, owner_type = $4, owner_id = $5,
            cedar_text = $6, actions = $7, managed = $8, created_by = $9,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(iamRoleColumns)
        """
    let role: IAMRoleSnapshot
    func makeBindings() throws -> PostgresBindings { try InsertIAMRole(role: role).makeBindings() }
}

private struct UpsertManagedIAMRole: IAMRoleStatement {
    static let sql = """
        INSERT INTO iam_roles (
            id, name, description, owner_type, owner_id, cedar_text, actions,
            managed, created_by, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT (id) DO UPDATE
        SET name = EXCLUDED.name,
            cedar_text = EXCLUDED.cedar_text,
            actions = EXCLUDED.actions,
            managed = true,
            updated_at = CURRENT_TIMESTAMP
        WHERE iam_roles.managed = true
        RETURNING \(iamRoleColumns)
        """
    let role: IAMRoleSnapshot
    func makeBindings() throws -> PostgresBindings { try InsertIAMRole(role: role).makeBindings() }
}

private struct DeleteIAMRole: PostgresPreparedStatement {
    static let sql = "DELETE FROM iam_roles WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings { bindings(id) }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteOwnedIAMRoles: PostgresPreparedStatement {
    static let sql = "DELETE FROM iam_roles WHERE owner_type = $1 AND owner_id = $2 RETURNING id"
    typealias Row = UUID
    let owner: IAMOwnerReference
    func makeBindings() -> PostgresBindings { bindings(owner.type, owner.id) }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct CountActiveRoleBindings: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM role_bindings WHERE role_id = $1 AND (expires_at IS NULL OR expires_at > $2)"
    typealias Row = Int
    let roleID: UUID
    let now: Date
    func makeBindings() -> PostgresBindings { bindings(roleID, now) }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private protocol IAMBindingStatement: PostgresPreparedStatement where Row == IAMRoleBindingSnapshot {}
private extension IAMBindingStatement {
    func decodeRow(_ row: PostgresRow) throws -> IAMRoleBindingSnapshot {
        let value = try row.decode((UUID, String, UUID, UUID, String, UUID, String?, Date?, UUID?, Date?).self)
        return IAMRoleBindingSnapshot(
            id: value.0,
            principalType: value.1,
            principalID: value.2,
            roleID: value.3,
            nodeType: value.4,
            nodeID: value.5,
            condition: value.6,
            expiresAt: value.7,
            createdBy: value.8,
            createdAt: value.9
        )
    }
}

private struct ListActiveIAMBindings: IAMBindingStatement {
    static let sql = """
        SELECT \(iamBindingColumns)
        FROM role_bindings
        WHERE (principal_type, principal_id) IN (
                SELECT input.principal_type, input.principal_id
                FROM unnest($1::text[], $2::uuid[]) AS input(principal_type, principal_id)
              )
          AND (node_type, node_id) IN (
                SELECT input.node_type, input.node_id
                FROM unnest($3::text[], $4::uuid[]) AS input(node_type, node_id)
              )
          AND (expires_at IS NULL OR expires_at > $5)
        ORDER BY node_type, node_id, principal_type, principal_id, role_id, id
        """
    let principalTypes: [String]
    let principalIDs: [UUID]
    let nodeTypes: [String]
    let nodeIDs: [UUID]
    let now: Date
    func makeBindings() throws -> PostgresBindings {
        var result = PostgresBindings(capacity: 5)
        result.append(principalTypes)
        result.append(principalIDs)
        result.append(nodeTypes)
        result.append(nodeIDs)
        result.append(now)
        return result
    }
}

private struct ListIAMBindingsAtNodes: IAMBindingStatement {
    static let sql = """
        SELECT \(iamBindingColumns)
        FROM role_bindings
        WHERE (node_type, node_id) IN (
                SELECT input.node_type, input.node_id
                FROM unnest($1::text[], $2::uuid[]) AS input(node_type, node_id)
              )
          AND (expires_at IS NULL OR expires_at > $3)
        ORDER BY node_type, node_id, principal_type, principal_id, role_id, id
        """
    let nodeTypes: [String]
    let nodeIDs: [UUID]
    let now: Date
    func makeBindings() throws -> PostgresBindings {
        var result = PostgresBindings(capacity: 3)
        result.append(nodeTypes)
        result.append(nodeIDs)
        result.append(now)
        return result
    }
}

private struct InsertIAMBinding: IAMBindingStatement {
    static let sql = """
        INSERT INTO role_bindings (
            id, principal_type, principal_id, role_id, node_type, node_id,
            condition, expires_at, created_by, created_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, CURRENT_TIMESTAMP)
        RETURNING \(iamBindingColumns)
        """
    let binding: IAMRoleBindingSnapshot
    func makeBindings() -> PostgresBindings {
        var result = PostgresBindings(capacity: 9)
        result.append(binding.id)
        result.append(binding.principalType)
        result.append(binding.principalID)
        result.append(binding.roleID)
        result.append(binding.nodeType)
        result.append(binding.nodeID)
        result.append(binding.condition)
        result.append(binding.expiresAt)
        result.append(binding.createdBy)
        return result
    }
}

private struct UpsertIAMBinding: IAMBindingStatement {
    static let sql = """
        INSERT INTO role_bindings (
            id, principal_type, principal_id, role_id, node_type, node_id,
            condition, expires_at, created_by, created_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, CURRENT_TIMESTAMP)
        ON CONFLICT (principal_type, principal_id, role_id, node_type, node_id)
        DO UPDATE SET expires_at = EXCLUDED.expires_at
        RETURNING \(iamBindingColumns)
        """
    let binding: IAMRoleBindingSnapshot
    func makeBindings() -> PostgresBindings {
        InsertIAMBinding(binding: binding).makeBindings()
    }
}

private struct ListActiveIAMBindingsForSubject: IAMBindingStatement {
    static let sql = """
        SELECT \(iamBindingColumns)
        FROM role_bindings
        WHERE principal_type = $1 AND principal_id = $2
          AND (expires_at IS NULL OR expires_at > $3)
        ORDER BY node_type, node_id, role_id, id
        """
    let subject: IAMOwnerReference
    let now: Date
    func makeBindings() -> PostgresBindings {
        var result = PostgresBindings(capacity: 3)
        result.append(subject.type)
        result.append(subject.id)
        result.append(now)
        return result
    }
}

private struct ListActiveIAMBindingsForSubjects: IAMBindingStatement {
    static let sql = """
        SELECT \(iamBindingColumns)
        FROM role_bindings
        WHERE (principal_type, principal_id) IN (
            SELECT input.principal_type, input.principal_id
            FROM unnest($1::text[], $2::uuid[]) AS input(principal_type, principal_id)
        )
          AND (expires_at IS NULL OR expires_at > $3)
        ORDER BY principal_type, principal_id, node_type, node_id, role_id, id
        """
    let subjects: [IAMOwnerReference]
    let now: Date
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(subjects.map(\.type))
        bindings.append(subjects.map(\.id))
        bindings.append(now)
        return bindings
    }
}

private struct ListIAMBindingsForSubject: IAMBindingStatement {
    static let sql = """
        SELECT \(iamBindingColumns)
        FROM role_bindings
        WHERE principal_type = $1 AND principal_id = $2
        ORDER BY node_type, node_id, role_id, id
        """
    let subject: IAMOwnerReference
    func makeBindings() -> PostgresBindings { bindings(subject.type, subject.id) }
}

private struct ListAllActiveIAMBindings: IAMBindingStatement {
    static let sql = """
        SELECT \(iamBindingColumns)
        FROM role_bindings
        WHERE expires_at IS NULL OR expires_at > $1
        ORDER BY node_type, node_id, principal_type, principal_id, role_id, id
        """
    let now: Date
    func makeBindings() -> PostgresBindings { bindings(now) }
}

private struct DeleteIAMBinding: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM role_bindings
        WHERE principal_type = $1 AND principal_id = $2 AND role_id = $3
          AND node_type = $4 AND node_id = $5
        RETURNING id
        """
    typealias Row = UUID
    let subject: IAMOwnerReference
    let roleID: UUID
    let node: IAMNodeReference
    func makeBindings() -> PostgresBindings {
        var result = PostgresBindings(capacity: 5)
        result.append(subject.type)
        result.append(subject.id)
        result.append(roleID)
        result.append(node.type)
        result.append(node.id)
        return result
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteIAMBindingsForSubjectAtNode: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM role_bindings
        WHERE principal_type = $1 AND principal_id = $2
          AND node_type = $3 AND node_id = $4
        RETURNING id
        """
    typealias Row = UUID
    let subject: IAMOwnerReference
    let node: IAMNodeReference
    func makeBindings() -> PostgresBindings {
        var result = PostgresBindings(capacity: 4)
        result.append(subject.type)
        result.append(subject.id)
        result.append(node.type)
        result.append(node.id)
        return result
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private protocol LockIAMMembershipNode: PostgresPreparedStatement where Row == UUID {}
private extension LockIAMMembershipNode {
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct LockIAMOrganization: LockIAMMembershipNode {
    static let sql = "SELECT id FROM organizations WHERE id = $1 FOR UPDATE"
    let id: UUID
    func makeBindings() -> PostgresBindings { bindings(id) }
}

private struct LockIAMOrganizationalUnit: LockIAMMembershipNode {
    static let sql = "SELECT id FROM organizational_units WHERE id = $1 FOR UPDATE"
    let id: UUID
    func makeBindings() -> PostgresBindings { bindings(id) }
}

private struct LockIAMProject: LockIAMMembershipNode {
    static let sql = "SELECT id FROM projects WHERE id = $1 FOR UPDATE"
    let id: UUID
    func makeBindings() -> PostgresBindings { bindings(id) }
}

private struct DeleteIAMBindingsForSubjects: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM role_bindings
        WHERE (principal_type, principal_id) IN (
            SELECT input.principal_type, input.principal_id
            FROM unnest($1::text[], $2::uuid[]) AS input(principal_type, principal_id)
        )
        RETURNING id
        """
    typealias Row = UUID
    let principalTypes: [String]
    let principalIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var result = PostgresBindings(capacity: 2)
        result.append(principalTypes)
        result.append(principalIDs)
        return result
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteIAMBindingsAtNodes: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM role_bindings
        WHERE (node_type, node_id) IN (
            SELECT input.node_type, input.node_id
            FROM unnest($1::text[], $2::uuid[]) AS input(node_type, node_id)
        )
        RETURNING id
        """
    typealias Row = UUID
    let nodeTypes: [String]
    let nodeIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var result = PostgresBindings(capacity: 2)
        result.append(nodeTypes)
        result.append(nodeIDs)
        return result
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private protocol IAMPolicyStatement: PostgresPreparedStatement where Row == IAMPolicySnapshot {}
private extension IAMPolicyStatement {
    func decodeRow(_ row: PostgresRow) throws -> IAMPolicySnapshot {
        let value = try row.decode((UUID, String, String?, String, UUID, String, String, Bool, UUID?, Date?, Date?).self)
        return IAMPolicySnapshot(
            id: value.0,
            name: value.1,
            description: value.2,
            ownerType: value.3,
            ownerID: value.4,
            cedarText: value.5,
            effect: value.6,
            enabled: value.7,
            createdBy: value.8,
            createdAt: value.9,
            updatedAt: value.10
        )
    }
}

private struct FindIAMPolicy: IAMPolicyStatement {
    static let sql = "SELECT \(iamPolicyColumns) FROM iam_policies WHERE id = $1 LIMIT 1"
    let id: UUID
    func makeBindings() -> PostgresBindings { bindings(id) }
}

private struct ListOwnedIAMPolicies: IAMPolicyStatement {
    static let sql = "SELECT \(iamPolicyColumns) FROM iam_policies WHERE owner_type = $1 AND owner_id = $2 ORDER BY name, id"
    let owner: IAMOwnerReference
    func makeBindings() -> PostgresBindings { bindings(owner.type, owner.id) }
}

private struct ListEnabledIAMPolicies: IAMPolicyStatement {
    static let sql = """
        SELECT \(iamPolicyColumns)
        FROM iam_policies
        WHERE enabled = true
          AND (owner_type, owner_id) IN (
                SELECT input.owner_type, input.owner_id
                FROM unnest($1::text[], $2::uuid[]) AS input(owner_type, owner_id)
          )
        ORDER BY name, id
        """
    let ownerTypes: [String]
    let ownerIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var result = PostgresBindings(capacity: 2)
        result.append(ownerTypes)
        result.append(ownerIDs)
        return result
    }
}

private struct ListAllEnabledIAMPolicies: IAMPolicyStatement {
    static let sql = "SELECT \(iamPolicyColumns) FROM iam_policies WHERE enabled = true ORDER BY id"
    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct InsertIAMPolicy: IAMPolicyStatement {
    static let sql = """
        INSERT INTO iam_policies (
            id, name, description, owner_type, owner_id, cedar_text, effect,
            enabled, created_by, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING \(iamPolicyColumns)
        """
    let policy: IAMPolicySnapshot
    func makeBindings() -> PostgresBindings {
        var result = PostgresBindings(capacity: 9)
        result.append(policy.id)
        result.append(policy.name)
        result.append(policy.description)
        result.append(policy.ownerType)
        result.append(policy.ownerID)
        result.append(policy.cedarText)
        result.append(policy.effect)
        result.append(policy.enabled)
        result.append(policy.createdBy)
        return result
    }
}

private struct ReplaceIAMPolicy: IAMPolicyStatement {
    static let sql = """
        UPDATE iam_policies
        SET name = $2, description = $3, owner_type = $4, owner_id = $5,
            cedar_text = $6, effect = $7, enabled = $8, created_by = $9,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(iamPolicyColumns)
        """
    let policy: IAMPolicySnapshot
    func makeBindings() -> PostgresBindings { InsertIAMPolicy(policy: policy).makeBindings() }
}

private struct DeleteIAMPolicy: PostgresPreparedStatement {
    static let sql = "DELETE FROM iam_policies WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings { bindings(id) }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteOwnedIAMPolicies: PostgresPreparedStatement {
    static let sql = "DELETE FROM iam_policies WHERE owner_type = $1 AND owner_id = $2 RETURNING id"
    typealias Row = UUID
    let owner: IAMOwnerReference
    func makeBindings() -> PostgresBindings { bindings(owner.type, owner.id) }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private protocol IAMGuardrailStatement: PostgresPreparedStatement where Row == IAMGuardrailSnapshot {}
private extension IAMGuardrailStatement {
    func decodeRow(_ row: PostgresRow) throws -> IAMGuardrailSnapshot {
        let value = try row.decode((UUID, String, String?, String, UUID, String, [String], String, UUID?, String, String?, Bool, UUID?, Date?, Date?, String?, Bool).self)
        return IAMGuardrailSnapshot(
            id: value.0,
            name: value.1,
            description: value.2,
            nodeType: value.3,
            nodeID: value.4,
            effect: value.5,
            actions: value.6,
            principalMatchKind: value.7,
            principalMatchID: value.8,
            resourceMatchKind: value.9,
            resourceMatchValue: value.10,
            enabled: value.11,
            createdBy: value.12,
            createdAt: value.13,
            updatedAt: value.14,
            cedarText: value.15,
            authored: value.16
        )
    }
}

private struct FindIAMGuardrail: IAMGuardrailStatement {
    static let sql = "SELECT \(iamGuardrailColumns) FROM iam_guardrails WHERE id = $1 LIMIT 1"
    let id: UUID
    func makeBindings() -> PostgresBindings { bindings(id) }
}

private struct ListAttachedIAMGuardrails: IAMGuardrailStatement {
    static let sql = "SELECT \(iamGuardrailColumns) FROM iam_guardrails WHERE node_type = $1 AND node_id = $2 ORDER BY name, id"
    let node: IAMNodeReference
    func makeBindings() -> PostgresBindings { bindings(node.type, node.id) }
}

private struct ListEnabledIAMGuardrails: IAMGuardrailStatement {
    static let sql = """
        SELECT \(iamGuardrailColumns)
        FROM iam_guardrails
        WHERE enabled = true
          AND (node_type, node_id) IN (
                SELECT input.node_type, input.node_id
                FROM unnest($1::text[], $2::uuid[]) AS input(node_type, node_id)
          )
        ORDER BY name, id
        """
    let nodeTypes: [String]
    let nodeIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var result = PostgresBindings(capacity: 2)
        result.append(nodeTypes)
        result.append(nodeIDs)
        return result
    }
}

private struct ListAllEnabledIAMGuardrails: IAMGuardrailStatement {
    static let sql = "SELECT \(iamGuardrailColumns) FROM iam_guardrails WHERE enabled = true ORDER BY id"
    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct ListIAMGuardrailsMissingCedarText: IAMGuardrailStatement {
    static let sql = "SELECT \(iamGuardrailColumns) FROM iam_guardrails WHERE cedar_text IS NULL ORDER BY id"
    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct BackfillIAMGuardrailCedarText: PostgresPreparedStatement {
    static let sql = """
        UPDATE iam_guardrails
        SET cedar_text = $2, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND cedar_text IS NULL
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let cedarText: String
    func makeBindings() -> PostgresBindings { bindings(id, cedarText) }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertIAMGuardrail: IAMGuardrailStatement {
    static let sql = """
        INSERT INTO iam_guardrails (
            id, name, description, node_type, node_id, effect, actions,
            principal_match_kind, principal_match_id, resource_match_kind,
            resource_match_value, enabled, created_by, created_at, updated_at,
            cedar_text, authored
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
            CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, $14, $15
        )
        RETURNING \(iamGuardrailColumns)
        """
    let guardrail: IAMGuardrailSnapshot
    func makeBindings() throws -> PostgresBindings {
        var result = PostgresBindings(capacity: 15)
        result.append(guardrail.id)
        result.append(guardrail.name)
        result.append(guardrail.description)
        result.append(guardrail.nodeType)
        result.append(guardrail.nodeID)
        result.append(guardrail.effect)
        result.append(guardrail.actions)
        result.append(guardrail.principalMatchKind)
        result.append(guardrail.principalMatchID)
        result.append(guardrail.resourceMatchKind)
        result.append(guardrail.resourceMatchValue)
        result.append(guardrail.enabled)
        result.append(guardrail.createdBy)
        result.append(guardrail.cedarText)
        result.append(guardrail.authored)
        return result
    }
}

private struct ReplaceIAMGuardrail: IAMGuardrailStatement {
    static let sql = """
        UPDATE iam_guardrails
        SET name = $2, description = $3, node_type = $4, node_id = $5,
            effect = $6, actions = $7, principal_match_kind = $8,
            principal_match_id = $9, resource_match_kind = $10,
            resource_match_value = $11, enabled = $12, created_by = $13,
            cedar_text = $14, authored = $15, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(iamGuardrailColumns)
        """
    let guardrail: IAMGuardrailSnapshot
    func makeBindings() throws -> PostgresBindings {
        try InsertIAMGuardrail(guardrail: guardrail).makeBindings()
    }
}

private struct DeleteIAMGuardrail: PostgresPreparedStatement {
    static let sql = "DELETE FROM iam_guardrails WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings { bindings(id) }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct CurrentPolicySetVersion: PostgresPreparedStatement {
    static let sql = "SELECT COALESCE(max(version), 0)::bigint FROM iam_policy_set_versions"
    typealias Row = Int
    func makeBindings() -> PostgresBindings { PostgresBindings() }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct LatestPolicySetVersion: PostgresPreparedStatement {
    static let sql = "SELECT \(policySetVersionColumns) FROM iam_policy_set_versions ORDER BY version DESC LIMIT 1"
    typealias Row = IAMPolicySetVersionSnapshot
    func makeBindings() -> PostgresBindings { PostgresBindings() }
    func decodeRow(_ row: PostgresRow) throws -> IAMPolicySetVersionSnapshot {
        let value = try row.decode((UUID, Int, String, UUID?, Date?).self)
        return IAMPolicySetVersionSnapshot(
            id: value.0,
            version: value.1,
            reason: value.2,
            changedBy: value.3,
            createdAt: value.4
        )
    }
}

private struct InsertPolicySetVersion: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO iam_policy_set_versions (id, version, reason, changed_by, created_at)
        VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)
        RETURNING version
        """
    typealias Row = Int
    let id: UUID
    let version: Int
    let reason: String
    let changedBy: UUID?
    func makeBindings() -> PostgresBindings {
        var result = PostgresBindings(capacity: 4)
        result.append(id)
        result.append(version)
        result.append(reason)
        result.append(changedBy)
        return result
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private protocol ExternalPrincipalStatement: PostgresPreparedStatement where Row == Bool {}

private extension ExternalPrincipalStatement {
    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private struct IsExternalUser: ExternalPrincipalStatement {
    static let sql = """
        SELECT NOT EXISTS (
            SELECT 1 FROM user_organizations
            WHERE user_id = $1 AND organization_id = $2
        )
        """
    let id: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings { bindings(id, organizationID) }
}

private struct IsExternalGroup: ExternalPrincipalStatement {
    static let sql = """
        SELECT COALESCE(
            (SELECT organization_id IS DISTINCT FROM $2 FROM groups WHERE id = $1),
            true
        )
        """
    let id: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings { bindings(id, organizationID) }
}

private struct IsExternalServiceAccount: ExternalPrincipalStatement {
    static let sql = """
        SELECT COALESCE(
            (
                SELECT COALESCE(project.organization_id, folder.organization_id)
                    IS DISTINCT FROM $2
                FROM service_accounts AS account
                JOIN projects AS project ON project.id = account.project_id
                LEFT JOIN organizational_units AS folder
                    ON folder.id = project.organizational_unit_id
                WHERE account.id = $1
            ),
            true
        )
        """
    let id: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings { bindings(id, organizationID) }
}

private struct IsExternalWorkload: ExternalPrincipalStatement {
    static let sql = """
        SELECT NOT EXISTS (
            SELECT 1 FROM workload_registrations
            WHERE id = $1 AND kind = 'workload' AND organization_id = $2
        )
        """
    let id: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings { bindings(id, organizationID) }
}

private struct IAMPolicyOwnerExists: PostgresPreparedStatement {
    static let sql = """
        SELECT CASE $1
            WHEN 'organization' THEN EXISTS (SELECT 1 FROM organizations WHERE id = $2)
            WHEN 'project' THEN EXISTS (SELECT 1 FROM projects WHERE id = $2)
            ELSE false
        END
        """
    typealias Row = Bool
    let type: String
    let id: UUID
    func makeBindings() -> PostgresBindings { bindings(type, id) }
    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private func bindings<Value: PostgresNonThrowingEncodable & Sendable>(_ value: Value) -> PostgresBindings {
    var result = PostgresBindings(capacity: 1)
    result.append(value)
    return result
}

private func bindings<First: PostgresNonThrowingEncodable & Sendable, Second: PostgresNonThrowingEncodable & Sendable>(
    _ first: First,
    _ second: Second
) -> PostgresBindings {
    var result = PostgresBindings(capacity: 2)
    result.append(first)
    result.append(second)
    return result
}

private func arrayBindings<Value: PostgresArrayEncodable & PostgresNonThrowingEncodable & Sendable>(
    _ values: [Value]
) throws -> PostgresBindings {
    var result = PostgresBindings(capacity: 1)
    result.append(values)
    return result
}
