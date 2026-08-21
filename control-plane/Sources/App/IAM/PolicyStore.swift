import ControlPlanePostgres
import Foundation
import Vapor

struct LegacyIAMPolicyRecord: Decodable, Equatable, Sendable {
    let id: UUID
    let name: String
    let description: String?
    let ownerType: String
    let ownerID: UUID
    let cedarText: String
    let effect: String
    let enabled: Bool
    let createdBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
}

/// Reads and writes authored Cedar policies (issue #606).
///
/// The write path is where an authored policy becomes real policy, so it is
/// where the three things a write must prove converge:
///
///   - its **effect** (`permit`/`forbid`) is read off the parsed text and
///     stored;
///   - its **resource scope** is contained inside the owner's subtree — an
///     org/project admin can only reach resources they already administer, and
///     this applies equally to forbids; and
///   - Cedar **accepts** it, compiled at write time against the schema the set
///     would have, so a policy that only fails at boot (`CedarPolicySetCache`
///     dropping the row) is caught here instead.
///
/// Authored-policy writes are policy-set writes: callers run them inside
/// `PolicySetVersionService.withPolicySetChange` and bump the version in the
/// same transaction — see `PolicyController`.
enum PolicyStore {
    private static let columns = """
        id, name, description, owner_type AS "ownerType", owner_id AS "ownerID",
        cedar_text AS "cedarText", effect, enabled, created_by AS "createdBy",
        created_at AS "createdAt", updated_at AS "updatedAt"
        """

    // MARK: - Preparing a write

    /// The Cedar text and derived effect a write will store.
    struct Prepared: Equatable, Sendable {
        let cedarText: String
        let effect: IAMPolicyEffect
        /// Whether the policy's principal scope is constrained at all (false =
        /// the unconstrained `principal`, which a `permit` grants to everyone).
        let principalConstrained: Bool
        /// The single principal a `permit` grants to, when named by `==`/`in`;
        /// nil for unconstrained / bare-type / non-resolvable principal scopes.
        let principalScope: AuthoredResourceScope?
    }

    /// Turn authored text into the row's stored fields, proving containment and
    /// that Cedar accepts it.
    ///
    /// `owner` is the org or project the policy will belong to; the resource
    /// scope must sit inside its subtree. The candidate is compiled against the
    /// schema built from the live role rows — the same schema the compiled set
    /// uses — so a policy referencing an attribute the schema does not declare
    /// is rejected here rather than silently dropped at boot.
    static func prepare(
        id: UUID,
        cedarText: String,
        ownerType: IAMRoleOwnerType,
        ownerID: UUID,
        engine: any CedarEngine,
        on db: PostgresStoreContext
    ) async throws -> Prepared {
        guard !cedarText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PolicyError.emptyCedarText
        }
        let policyID = PolicyDescriptor.policyID(id)
        let shape = try CedarAuthoredPolicyInspector.describe(cedarText: cedarText, policyID: policyID)

        try await requireContained(shape, ownerType: ownerType, ownerID: ownerID, on: db)
        try await compileCandidate(policyID: policyID, cedarText: cedarText, engine: engine, on: db)

        return Prepared(
            cedarText: cedarText, effect: shape.effect,
            principalConstrained: shape.principalConstrained, principalScope: shape.principalScope)
    }

    /// Native-persistence variant used by production policy routes. Hierarchy
    /// containment still uses the transitional resource-tree reader until its
    /// cohort moves, while role schema assembly comes from the native IAM
    /// module.
    static func prepare(
        id: UUID,
        cedarText: String,
        ownerType: IAMRoleOwnerType,
        ownerID: UUID,
        engine: any CedarEngine,
        using iam: IAMPersistence
    ) async throws -> Prepared {
        guard !cedarText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PolicyError.emptyCedarText
        }
        let policyID = PolicyDescriptor.policyID(id)
        let shape = try CedarAuthoredPolicyInspector.describe(cedarText: cedarText, policyID: policyID)

        try await requireContained(
            shape,
            ownerType: ownerType,
            ownerID: ownerID,
            using: iam
        )
        let roles = try await iam.allRoles().map(RoleDescriptor.init(row:))
        try compileCandidate(
            policyID: policyID,
            cedarText: cedarText,
            roles: roles,
            engine: engine
        )

        return Prepared(
            cedarText: cedarText,
            effect: shape.effect,
            principalConstrained: shape.principalConstrained,
            principalScope: shape.principalScope
        )
    }

    /// Prove the policy's resource scope names something inside the owner's
    /// subtree.
    ///
    /// The scope has to name a concrete resource (`resource == X` /
    /// `resource in X`), because an unconfined `resource` reaches every
    /// resource of a type across every org — exactly what an org/project admin
    /// must not be able to author. Walking the named resource's ancestry and
    /// requiring the owner node on the chain is the same containment the tree
    /// already expresses for bindings and ceilings.
    ///
    /// **This is checked at write time only.** The compiled set evaluates every
    /// enabled policy globally — ownership scopes nothing at evaluation time, so
    /// the resource scope *is* the whole containment guarantee. That rests on a
    /// load-bearing invariant: a resource a policy names by `==`/`in` never
    /// leaves its owner's subtree. It holds today because folder moves are
    /// same-org (`OrganizationalUnitController.move` rejects a cross-org
    /// parent), so the org boundary can never be crossed. If a resource a policy
    /// pins by id becomes re-parentable across projects, a policy would keep
    /// reaching a resource its owner no longer administers — re-validating or
    /// disabling affected policies on such a move belongs with the #484
    /// symcc follow-up.
    private static func requireContained(
        _ shape: AuthoredPolicyShape,
        ownerType: IAMRoleOwnerType,
        ownerID: UUID,
        on db: PostgresStoreContext
    ) async throws {
        guard let ownerNodeType = ownerType.nodeType else {
            throw PolicyError.uncreatableOwnerType(ownerType.rawValue)
        }
        let ownerNode = IAMNode(type: ownerNodeType, id: ownerID)

        guard let scope = shape.resourceScope else {
            throw PolicyError.unscopedResource
        }
        guard let resourceNodeType = scope.type.nodeType else {
            throw PolicyError.principalResourceScope(scope.type.rawValue)
        }

        let resourceNode = IAMNode(type: resourceNodeType, id: scope.id)
        let chain = try await IAMResourceTree.ancestors(of: resourceNode, on: db)
        guard chain.contains(ownerNode) else {
            throw PolicyError.outOfScope(
                owner: "\(ownerType.rawValue)/\(ownerID)",
                resource: "\(scope.type.rawValue)/\(scope.id)")
        }
    }

    private static func requireContained(
        _ shape: AuthoredPolicyShape,
        ownerType: IAMRoleOwnerType,
        ownerID: UUID,
        using iam: IAMPersistence
    ) async throws {
        guard let ownerNodeType = ownerType.nodeType else {
            throw PolicyError.uncreatableOwnerType(ownerType.rawValue)
        }
        let ownerNode = IAMNode(type: ownerNodeType, id: ownerID)
        guard let scope = shape.resourceScope else {
            throw PolicyError.unscopedResource
        }
        guard let resourceNodeType = scope.type.nodeType else {
            throw PolicyError.principalResourceScope(scope.type.rawValue)
        }
        let resourceNode = IAMNode(type: resourceNodeType, id: scope.id)
        let chain = try await IAMResourceTree.ancestors(of: resourceNode, using: iam)
        guard chain.contains(ownerNode) else {
            throw PolicyError.outOfScope(
                owner: "\(ownerType.rawValue)/\(ownerID)",
                resource: "\(scope.type.rawValue)/\(scope.id)"
            )
        }
    }

    /// Compile the candidate against the schema the store would have, the same
    /// per-policy validation `CedarPolicySetCache` runs at boot.
    private static func compileCandidate(
        policyID: String,
        cedarText: String,
        engine: any CedarEngine,
        on db: PostgresStoreContext
    ) async throws {
        let roles = try await RoleStore.allDescriptors(on: db)
        try compileCandidate(
            policyID: policyID,
            cedarText: cedarText,
            roles: roles,
            engine: engine
        )
    }

    private static func compileCandidate(
        policyID: String,
        cedarText: String,
        roles: [RoleDescriptor],
        engine: any CedarEngine
    ) throws {
        let schemaText = CedarSchemaBuilder.schemaText(roles: roles)
        let source = CedarPolicySource(id: policyID, text: cedarText)
        if let issue = engine.policyIssue(schemaText: schemaText, policy: source) {
            throw PolicyError.rejectedByCedar(issue)
        }
    }

    // MARK: - Queries

    /// The policies a node owns.
    static func owned(
        by ownerType: IAMRoleOwnerType, ownerID: UUID, on db: PostgresStoreContext
    ) async throws -> [LegacyIAMPolicyRecord] {
        try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns) FROM iam_policies
            WHERE owner_type = \(bind: ownerType.rawValue) AND owner_id = \(bind: ownerID)
            ORDER BY name, id
            """
        ).all(decoding: LegacyIAMPolicyRecord.self)
    }

    static func owned(
        by ownerType: IAMRoleOwnerType,
        ownerID: UUID,
        using iam: IAMPersistence
    ) async throws -> [IAMPolicySnapshot] {
        try await iam.policies(
            ownedBy: IAMOwnerReference(type: ownerType.rawValue, id: ownerID)
        )
    }

    /// Every enabled authored policy owned by an organization or project on
    /// `chain` — the policies that could be in force at a node beneath them.
    ///
    /// Ownership scopes a policy the way it scopes a role: a project's policy
    /// is in force on the project and below, and nowhere else. Whether it
    /// actually reaches a given resource is a further containment question the
    /// caller answers per policy (see `WhoCanService`).
    static func inScope(
        along chain: [IAMNode], on db: PostgresStoreContext
    ) async throws -> [LegacyIAMPolicyRecord] {
        let organizationIDs = chain.filter { $0.type == .organization }.map(\.id)
        let projectIDs = chain.filter { $0.type == .project }.map(\.id)
        guard !organizationIDs.isEmpty || !projectIDs.isEmpty else { return [] }
        let sql = try requireSQL(db)
        var query: PostgresSQLQuery =
            "SELECT \(unsafeRaw: columns) FROM iam_policies WHERE enabled = true AND (FALSE"
        if !organizationIDs.isEmpty {
            query +=
                " OR (owner_type = 'organization' AND owner_id = ANY(\(bind: organizationIDs)))"
        }
        if !projectIDs.isEmpty {
            query += " OR (owner_type = 'project' AND owner_id = ANY(\(bind: projectIDs)))"
        }
        query += ") ORDER BY name, id"
        return try await sql.raw(query).all(decoding: LegacyIAMPolicyRecord.self)
    }

    static func inScope(
        along chain: [IAMNode],
        using iam: IAMPersistence
    ) async throws -> [IAMPolicySnapshot] {
        let owners = chain.compactMap { node -> IAMOwnerReference? in
            switch node.type {
            case .organization:
                return IAMOwnerReference(type: IAMRoleOwnerType.organization.rawValue, id: node.id)
            case .project:
                return IAMOwnerReference(type: IAMRoleOwnerType.project.rawValue, id: node.id)
            default:
                return nil
            }
        }
        return try await iam.enabledPolicies(owners: owners)
    }

    // MARK: - Writes

    /// Insert a policy row, translating a name collision into a `409`.
    static func create(
        id: UUID,
        name: String,
        description: String?,
        ownerType: IAMRoleOwnerType,
        ownerID: UUID,
        prepared: Prepared,
        createdBy: UUID?,
        enabled: Bool,
        on db: PostgresStoreContext
    ) async throws -> LegacyIAMPolicyRecord {
        guard IAMRoleOwnerType.creatableOwners.contains(ownerType) else {
            throw PolicyError.uncreatableOwnerType(ownerType.rawValue)
        }
        do {
            guard let policy = try await requireSQL(db).raw(
                """
                INSERT INTO iam_policies (
                    id, name, description, owner_type, owner_id, cedar_text, effect,
                    enabled, created_by, created_at, updated_at
                ) VALUES (
                    \(bind: id), \(bind: name), \(bind: description),
                    \(bind: ownerType.rawValue), \(bind: ownerID),
                    \(bind: prepared.cedarText), \(bind: prepared.effect.rawValue),
                    \(bind: enabled), \(bind: createdBy), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
                )
                RETURNING \(unsafeRaw: columns)
                """
            ).first(decoding: LegacyIAMPolicyRecord.self) else {
                throw IAMPersistenceError.unexpectedRowCount(expected: 1, actual: 0)
            }
            return policy
        } catch let error as any PostgresConstraintError where error.isConstraintFailure {
            throw PolicyError.duplicateName(name)
        }
    }

    static func create(
        id: UUID,
        name: String,
        description: String?,
        ownerType: IAMRoleOwnerType,
        ownerID: UUID,
        prepared: Prepared,
        createdBy: UUID?,
        enabled: Bool,
        in transaction: IAMPolicySetTransaction
    ) async throws -> IAMPolicySnapshot {
        guard IAMRoleOwnerType.creatableOwners.contains(ownerType) else {
            throw PolicyError.uncreatableOwnerType(ownerType.rawValue)
        }
        do {
            return try await transaction.createPolicy(
                IAMPolicySnapshot(
                    id: id,
                    name: name,
                    description: description,
                    ownerType: ownerType.rawValue,
                    ownerID: ownerID,
                    cedarText: prepared.cedarText,
                    effect: prepared.effect.rawValue,
                    enabled: enabled,
                    createdBy: createdBy
                )
            )
        } catch IAMPersistenceError.duplicatePolicyName {
            throw PolicyError.duplicateName(name)
        }
    }

    @discardableResult
    static func deleteOwned(
        by ownerType: IAMRoleOwnerType,
        ownerID: UUID,
        in transaction: IAMPolicySetTransaction
    ) async throws -> Int {
        try await transaction.deletePolicies(
            ownedBy: IAMOwnerReference(type: ownerType.rawValue, id: ownerID)
        )
    }

    /// Delete every policy a node owns, returning how many went.
    ///
    /// Called from the org and project delete cascades: a policy outliving its
    /// owner would be attributable to nothing in every listing while still
    /// contributing a permit or forbid to the compiled set.
    @discardableResult
    static func deleteOwned(
        by ownerType: IAMRoleOwnerType, ownerID: UUID, on db: PostgresStoreContext
    ) async throws -> Int {
        struct Identifier: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            """
            DELETE FROM iam_policies
            WHERE owner_type = \(bind: ownerType.rawValue) AND owner_id = \(bind: ownerID)
            RETURNING id
            """
        ).all(decoding: Identifier.self).count
    }

    static func count(on db: PostgresStoreContext) async throws -> Int {
        struct CountRow: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            "SELECT count(*)::bigint AS count FROM iam_policies"
        ).first(decoding: CountRow.self)?.count ?? 0
    }

    private static func requireSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
        guard let sql = db as? PostgresStoreContext else {
            throw IAMPersistenceError.unexpectedRowCount(expected: 1, actual: 0)
        }
        return sql
    }
}

/// Why an authored-policy write was refused, beyond what the Cedar text itself
/// says (`CedarAuthoredPolicyTextError`).
enum PolicyError: Error, AbortError, Equatable {
    case emptyCedarText
    case uncreatableOwnerType(String)
    case unknownOwner(String)
    case unscopedResource
    case principalResourceScope(String)
    case outOfScope(owner: String, resource: String)
    case duplicateName(String)
    case rejectedByCedar(String)

    var status: HTTPResponseStatus {
        switch self {
        case .emptyCedarText, .uncreatableOwnerType, .unscopedResource, .principalResourceScope,
            .outOfScope, .rejectedByCedar:
            return .badRequest
        case .unknownOwner:
            return .notFound
        case .duplicateName:
            return .conflict
        }
    }

    var reason: String {
        switch self {
        case .emptyCedarText:
            return "A policy needs 'cedarText' — the Cedar permit or forbid to store."
        case .uncreatableOwnerType(let type):
            return
                "Authored policies are owned by an organization or a project; '\(type)' is not one of those."
        case .unknownOwner(let owner):
            return "No such policy owner: \(owner)."
        case .unscopedResource:
            return
                "A policy's resource scope must name a concrete resource inside its owner — `resource == <Type>::\"<id>\"` or `resource in <Type>::\"<id>\"`. An unscoped `resource` would reach every resource of that type across every organization."
        case .principalResourceScope(let type):
            return
                "The policy's resource scope names '\(type)', which is a principal, not a resource. Scope the policy to a resource inside its owner."
        case .outOfScope(let owner, let resource):
            return
                "The policy's resource scope (\(resource)) is not inside its owner (\(owner)). An org or project admin can only author policies that reach their own subtree."
        case .duplicateName(let name):
            return "A policy named '\(name)' already exists for this owner."
        case .rejectedByCedar(let detail):
            return "Cedar rejected the policy: \(detail)"
        }
    }
}
