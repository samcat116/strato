import ControlPlanePostgres
import Foundation
import Vapor

struct LegacyIAMRoleRecord: Decodable, Equatable, Sendable {
    let id: UUID
    let name: String
    let description: String?
    let ownerType: String
    let ownerID: UUID
    let cedarText: String
    let actions: [String]
    let managed: Bool
    let createdBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
}

/// Reads and writes role definitions (issue #605).
///
/// The write path is where a role becomes real policy, so it is where the two
/// input modes converge: picking actions generates the canonical permit, and
/// advanced text is inspected until it is known to have the same shape. Both
/// end up as the same row, with `actions` derived from the parsed policy
/// (`CedarPolicyInspector`) rather than from whichever field the client sent.
///
/// Role writes are policy-set writes: callers run them inside
/// `PolicySetVersionService.withPolicySetChange` and bump the version in the
/// same transaction — see `RoleController`. Bindings *referencing* a role are
/// data and bump nothing.
enum RoleStore {
    private static let columns = """
        id, name, description, owner_type AS "ownerType", owner_id AS "ownerID",
        cedar_text AS "cedarText", actions, managed, created_by AS "createdBy",
        created_at AS "createdAt", updated_at AS "updatedAt"
        """

    // MARK: - Preparing a write

    /// The Cedar text and derived action list a write will store.
    struct Prepared: Equatable, Sendable {
        let cedarText: String
        let actions: [String]
    }

    /// Turn either input mode into the row's Cedar text plus derived actions,
    /// and prove Cedar accepts the result.
    ///
    /// `existingRoles` are the other role rows: they contribute their grants
    /// fields to the candidate schema, which is what makes this a real
    /// compile of the policy *this row would produce* rather than of a policy
    /// in isolation. A role that only fails against the live schema — an
    /// action the registry no longer declares, a `has` the strict validator
    /// can prove false — is caught here, at the write, instead of being
    /// discovered by `CedarPolicySetCache` skipping the row at boot and
    /// leaving an admin with a role that grants nothing.
    static func prepare(
        id: UUID,
        actions: [String]?,
        cedarText: String?,
        existingRoles: [RoleDescriptor],
        engine: any CedarEngine
    ) throws -> Prepared {
        let text: String
        switch (actions, cedarText) {
        case (.some, .some):
            throw RoleError.ambiguousInput
        case (.none, .none):
            throw RoleError.missingInput
        case (.some(let actions), .none):
            guard !actions.isEmpty else { throw CedarRoleTextError.noActions }
            for action in actions where !IAMRoleRegistry.allActions.contains(action) {
                throw CedarRoleTextError.unknownAction(action)
            }
            text = RoleDescriptor.canonicalPermitText(id: id, actions: Set(actions))
        case (.none, .some(let cedarText)):
            text = cedarText
        }

        let inspection = try CedarPolicyInspector.inspect(cedarText: text, roleID: id)
        try compileCandidate(id: id, cedarText: text, existingRoles: existingRoles, engine: engine)
        return Prepared(cedarText: text, actions: inspection.actions)
    }

    /// Validate the candidate policy against the schema the store would have
    /// once this row exists.
    ///
    /// Per-policy rather than whole-set: Cedar validates policies
    /// individually (it is why `CedarPolicySetCache` can drop one bad row
    /// instead of freezing the set), so compiling the candidate against the
    /// candidate schema surfaces the same errors the cache would, attributed
    /// to the row being written.
    private static func compileCandidate(
        id: UUID,
        cedarText: String,
        existingRoles: [RoleDescriptor],
        engine: any CedarEngine
    ) throws {
        let candidate = RoleDescriptor(id: id, name: "candidate", cedarText: cedarText, actions: [])
        let roles = existingRoles.filter { $0.id != id } + [candidate]
        let schemaText = CedarSchemaBuilder.schemaText(roles: roles)
        let source = CedarPolicySource(id: candidate.policyID, text: cedarText)
        if let issue = engine.policyIssue(schemaText: schemaText, policy: source) {
            throw CedarRoleTextError.rejectedByCedar(issue)
        }
    }

    /// Every role row as a descriptor — the candidate schema's other half.
    static func allDescriptors(using iam: IAMPersistence) async throws -> [RoleDescriptor] {
        try await iam.allRoles().map(RoleDescriptor.init(row:))
    }

    /// Transitional overload for policy/guardrail preparation paths that have
    /// not yet moved their surrounding hierarchy transaction to PostgresNIO.
    /// Deleted with the last Fluent transaction in this cohort.
    static func allDescriptors(on db: PostgresStoreContext) async throws -> [RoleDescriptor] {
        try await legacyRoles(on: db).map(RoleDescriptor.init(row:))
    }

    // MARK: - Queries

    /// The roles a node owns.
    static func owned(
        by ownerType: IAMRoleOwnerType, ownerID: UUID, using iam: IAMPersistence
    ) async throws -> [IAMRoleSnapshot] {
        try await iam.roles(
            ownedBy: IAMOwnerReference(type: ownerType.rawValue, id: ownerID)
        )
    }

    /// The roles bindable on a node: the platform-owned defaults plus every
    /// role owned by an organization or project on the node's ancestor chain.
    ///
    /// Ownership is what scopes a role, so a project's role is bindable on the
    /// project and everything beneath it and nowhere else — the same
    /// containment the chain already expresses for bindings and ceilings.
    static func bindable(along chain: [IAMNode], using iam: IAMPersistence) async throws -> [IAMRoleSnapshot] {
        try await iam.bindableRoles(owners: ownerReferences(along: chain))
    }

    /// The bindable roles at a node carrying a given name — the write path's
    /// half of `bindable`, so a name that listing just handed out is a name a
    /// grant can be written with (STR-111).
    ///
    /// Plural because a name is unique only within its owner: two owners on
    /// one chain can each define `deployer`, and picking one silently would be
    /// a grant nobody asked for. The caller decides — `MemberRoleResolver`
    /// refuses and names the candidates.
    static func bindable(
        named name: String, along chain: [IAMNode], using iam: IAMPersistence
    ) async throws -> [IAMRoleSnapshot] {
        try await iam.bindableRoles(owners: ownerReferences(along: chain)).filter { $0.name == name }
    }

    /// The owner predicate both `bindable` forms share, assembled from
    /// `IAMRoleOwnerType.ownerIDs(along:)` — the same containment
    /// `MemberRoleResolver` validates a by-id grant against, so the listing
    /// and the write path cannot disagree about what a node can bind.
    private static func ownerReferences(along chain: [IAMNode]) -> [IAMOwnerReference] {
        IAMRoleOwnerType.allCases.flatMap { ownerType in
            (ownerType.ownerIDs(along: chain) ?? []).map {
                IAMOwnerReference(type: ownerType.rawValue, id: $0)
            }
        }
    }

    /// How many live bindings name this role — what makes a delete a `409`.
    ///
    /// Active only: an expired binding grants nothing, so it is not a reason to
    /// keep a role around, and the dangling reference it leaves behind is the
    /// same harmless under-grant every read path already drops
    /// (`iam_roles`).
    static func activeBindingCount(roleID: UUID, using iam: IAMPersistence) async throws -> Int {
        try await iam.activeBindingCount(roleID: roleID)
    }

    // MARK: - Writes

    /// Insert a role row, translating a name collision into a `409`.
    static func create(
        id: UUID,
        name: String,
        description: String?,
        ownerType: IAMRoleOwnerType,
        ownerID: UUID,
        prepared: Prepared,
        createdBy: UUID?,
        in transaction: IAMPolicySetTransaction
    ) async throws -> IAMRoleSnapshot {
        guard IAMRoleOwnerType.creatableOwners.contains(ownerType) else {
            throw RoleError.uncreatableOwnerType(ownerType.rawValue)
        }
        let role = IAMRoleSnapshot(
            id: id,
            name: name,
            description: description,
            ownerType: ownerType.rawValue,
            ownerID: ownerID,
            cedarText: prepared.cedarText,
            actions: prepared.actions,
            managed: false,
            createdBy: createdBy
        )
        do {
            return try await transaction.createRole(role)
        } catch IAMPersistenceError.duplicateRoleName {
            throw RoleError.duplicateName(name)
        }
    }

    /// Delete every role a node owns, returning how many went.
    ///
    /// Called from the org and project delete cascades: a role outliving its
    /// owner would be unbindable everywhere and invisible in every listing,
    /// while still contributing a grants-field pair to the schema.
    @discardableResult
    static func deleteOwned(
        by ownerType: IAMRoleOwnerType, ownerID: UUID, in transaction: IAMPolicySetTransaction
    ) async throws -> Int {
        try await transaction.deleteRoles(
            ownedBy: IAMOwnerReference(type: ownerType.rawValue, id: ownerID)
        )
    }

    /// Transitional overload for owner-deletion transactions that still
    /// contain non-IAM Fluent work. Removed when hierarchy ownership moves.
    @discardableResult
    static func deleteOwned(
        by ownerType: IAMRoleOwnerType, ownerID: UUID, on db: PostgresStoreContext
    ) async throws -> Int {
        struct Identifier: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            """
            DELETE FROM iam_roles
            WHERE owner_type = \(bind: ownerType.rawValue) AND owner_id = \(bind: ownerID)
            RETURNING id
            """
        ).all(decoding: Identifier.self).count
    }

    static func legacyRole(id: UUID, on db: PostgresStoreContext) async throws -> LegacyIAMRoleRecord? {
        try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM iam_roles WHERE id = \(bind: id)"
        ).first(decoding: LegacyIAMRoleRecord.self)
    }

    static func legacyRoles(ids: [UUID], on db: PostgresStoreContext) async throws -> [LegacyIAMRoleRecord] {
        guard !ids.isEmpty else { return [] }
        return try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM iam_roles WHERE id = ANY(\(bind: ids)) ORDER BY id"
        ).all(decoding: LegacyIAMRoleRecord.self)
    }

    static func legacyRoles(on db: PostgresStoreContext) async throws -> [LegacyIAMRoleRecord] {
        try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM iam_roles ORDER BY id"
        ).all(decoding: LegacyIAMRoleRecord.self)
    }

    static func legacyRoleCount(managed: Bool? = nil, on db: PostgresStoreContext) async throws -> Int {
        struct CountRow: Decodable { let count: Int }
        let sql = try requireSQL(db)
        let row: CountRow?
        if let managed {
            row = try await sql.raw(
                "SELECT count(*)::bigint AS count FROM iam_roles WHERE managed = \(bind: managed)"
            ).first(decoding: CountRow.self)
        } else {
            row = try await sql.raw("SELECT count(*)::bigint AS count FROM iam_roles")
                .first(decoding: CountRow.self)
        }
        return row?.count ?? 0
    }

    static func insertLegacy(_ role: IAMRoleSnapshot, on db: PostgresStoreContext) async throws
        -> LegacyIAMRoleRecord
    {
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO iam_roles (
                id, name, description, owner_type, owner_id, cedar_text, actions,
                managed, created_by, created_at, updated_at
            ) VALUES (
                \(bind: role.id), \(bind: role.name), \(bind: role.description),
                \(bind: role.ownerType), \(bind: role.ownerID), \(bind: role.cedarText),
                \(bind: role.actions), \(bind: role.managed), \(bind: role.createdBy),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: LegacyIAMRoleRecord.self) else {
            throw IAMPersistenceError.unexpectedRowCount(expected: 1, actual: 0)
        }
        return row
    }

    static func replaceLegacy(_ role: IAMRoleSnapshot, on db: PostgresStoreContext) async throws
        -> LegacyIAMRoleRecord?
    {
        try await requireSQL(db).raw(
            """
            UPDATE iam_roles SET
                name = \(bind: role.name), description = \(bind: role.description),
                owner_type = \(bind: role.ownerType), owner_id = \(bind: role.ownerID),
                cedar_text = \(bind: role.cedarText), actions = \(bind: role.actions),
                managed = \(bind: role.managed), created_by = \(bind: role.createdBy),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: role.id)
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: LegacyIAMRoleRecord.self)
    }

    private static func requireSQL(_ db: PostgresStoreContext) throws -> PostgresStoreContext {
        guard let sql = db as? PostgresStoreContext else {
            throw IAMPersistenceError.unexpectedRowCount(expected: 1, actual: 0)
        }
        return sql
    }
}

/// Why a role write was refused, beyond what the Cedar text itself says
/// (`CedarRoleTextError`).
enum RoleError: Error, AbortError, Equatable {
    case ambiguousInput
    case missingInput
    case uncreatableOwnerType(String)
    case unknownOwner(String)
    case managedRoleImmutable(String)
    case duplicateName(String)
    case roleInUse(String, Int)

    var status: HTTPResponseStatus {
        switch self {
        case .ambiguousInput, .missingInput, .uncreatableOwnerType:
            return .badRequest
        case .unknownOwner:
            return .notFound
        case .managedRoleImmutable:
            return .forbidden
        case .duplicateName, .roleInUse:
            return .conflict
        }
    }

    var reason: String {
        switch self {
        case .ambiguousInput:
            return
                "Send either 'actions' or 'cedarText', not both — the server generates the permit from an action list, and hand-written text supersedes it."
        case .missingInput:
            return "A role needs either 'actions' (the server generates the permit) or 'cedarText' (advanced)."
        case .uncreatableOwnerType(let type):
            return
                "Roles are owned by an organization or a project; '\(type)' is not one of those. The platform-owned roles are the seeded defaults and are managed by the deployment."
        case .unknownOwner(let owner):
            return "No such role owner: \(owner)."
        case .managedRoleImmutable(let name):
            return
                "'\(name)' is a seeded role managed by the deployment and cannot be changed through the API. Create a role of your own instead."
        case .duplicateName(let name):
            return "A role named '\(name)' already exists for this owner."
        case .roleInUse(let name, let count):
            return
                "'\(name)' still has \(count) active binding\(count == 1 ? "" : "s"). Revoke them before deleting the role — deleting it out from under them would silently drop the access they grant."
        }
    }
}

extension Application {
    private struct CedarEngineKey: StorageKey, LockKey {
        typealias Value = any CedarEngine
    }

    /// The engine role writes compile candidates against.
    ///
    /// Settable so tests that only care about the API's shape can inject a
    /// no-op engine, the way `guardrailAnalyzer` is; the compiled-set cache
    /// keeps its own instance, since it is on the boot path rather than the
    /// request path.
    var cedarEngine: any CedarEngine {
        get { lazyService(CedarEngineKey.self) { SwiftCedarEngine() } }
        set {
            let lock = locks.lock(for: CedarEngineKey.self)
            lock.lock()
            defer { lock.unlock() }
            setStorageValue(CedarEngineKey.self, to: newValue)
        }
    }
}
