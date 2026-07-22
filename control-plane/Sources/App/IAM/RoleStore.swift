import Fluent
import Foundation
import Vapor

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

    /// The owner types the API accepts. Platform rows are the seeded defaults
    /// reconciled by `RoleRegistrySync`; nothing creates one over HTTP, and a
    /// request that asks to is told so rather than having its owner quietly
    /// coerced.
    static let creatableOwnerTypes: Set<IAMRoleOwnerType> = [.organization, .project]

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
    static func allDescriptors(on db: any Database) async throws -> [RoleDescriptor] {
        try await IAMRoleDefinition.query(on: db).all().compactMap(RoleDescriptor.init(row:))
    }

    // MARK: - Queries

    /// The roles a node owns.
    static func owned(
        by ownerType: IAMRoleOwnerType, ownerID: UUID, on db: any Database
    ) async throws -> [IAMRoleDefinition] {
        try await IAMRoleDefinition.query(on: db)
            .filter(\.$ownerType == ownerType.rawValue)
            .filter(\.$ownerID == ownerID)
            .sort(\.$name)
            .all()
    }

    /// The roles bindable on a node: the platform-owned defaults plus every
    /// role owned by an organization or project on the node's ancestor chain.
    ///
    /// Ownership is what scopes a role, so a project's role is bindable on the
    /// project and everything beneath it and nowhere else — the same
    /// containment the chain already expresses for bindings and ceilings.
    static func bindable(along chain: [IAMNode], on db: any Database) async throws -> [IAMRoleDefinition] {
        let organizationIDs = chain.filter { $0.type == .organization }.map(\.id)
        let projectIDs = chain.filter { $0.type == .project }.map(\.id)
        return try await IAMRoleDefinition.query(on: db)
            .group(.or) { anyOwner in
                anyOwner.filter(\.$ownerType == IAMRoleOwnerType.platform.rawValue)
                if !organizationIDs.isEmpty {
                    anyOwner.group(.and) { owner in
                        owner.filter(\.$ownerType == IAMRoleOwnerType.organization.rawValue)
                        owner.filter(\.$ownerID ~~ organizationIDs)
                    }
                }
                if !projectIDs.isEmpty {
                    anyOwner.group(.and) { owner in
                        owner.filter(\.$ownerType == IAMRoleOwnerType.project.rawValue)
                        owner.filter(\.$ownerID ~~ projectIDs)
                    }
                }
            }
            .sort(\.$name)
            .all()
    }

    /// How many live bindings name this role — what makes a delete a `409`.
    ///
    /// Active only: an expired binding grants nothing, so it is not a reason to
    /// keep a role around, and the dangling reference it leaves behind is the
    /// same harmless under-grant every read path already drops
    /// (`IAMRoleDefinition`).
    static func activeBindingCount(roleID: UUID, on db: any Database) async throws -> Int {
        try await RoleBinding.query(on: db)
            .filter(\.$role == roleID.uuidString)
            .active()
            .count()
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
        on db: any Database
    ) async throws -> IAMRoleDefinition {
        guard creatableOwnerTypes.contains(ownerType) else {
            throw RoleError.uncreatableOwnerType(ownerType.rawValue)
        }
        let role = IAMRoleDefinition(
            id: id,
            name: name,
            description: description,
            ownerType: ownerType,
            ownerID: ownerID,
            cedarText: prepared.cedarText,
            actions: prepared.actions,
            managed: false,
            createdBy: createdBy
        )
        do {
            try await role.create(on: db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw RoleError.duplicateName(name)
        }
        return role
    }

    /// Delete every role a node owns, returning how many went.
    ///
    /// Called from the org and project delete cascades: a role outliving its
    /// owner would be unbindable everywhere and invisible in every listing,
    /// while still contributing a grants-field pair to the schema.
    @discardableResult
    static func deleteOwned(
        by ownerType: IAMRoleOwnerType, ownerID: UUID, on db: any Database
    ) async throws -> Int {
        let owned = try await IAMRoleDefinition.query(on: db)
            .filter(\.$ownerType == ownerType.rawValue)
            .filter(\.$ownerID == ownerID)
            .all()
        guard !owned.isEmpty else { return 0 }
        try await IAMRoleDefinition.query(on: db)
            .filter(\.$ownerType == ownerType.rawValue)
            .filter(\.$ownerID == ownerID)
            .delete()
        return owned.count
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
            storage[CedarEngineKey.self] = newValue
        }
    }
}
