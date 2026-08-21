import ControlPlanePostgres
import Vapor

/// The org-or-OU owner shared by organization-scoped infrastructure resources
/// (agents, sites, registration tokens; logical networks join in a later
/// phase). Mirrors Project's parent model: exactly one of organization /
/// organizational unit, stored as two nullable FK columns with the one-of
/// invariant enforced in application code.
enum OrganizationScope: Equatable, Sendable {
    case organization(UUID)
    case organizationalUnit(UUID)

    /// The typed IAM node naming this scope's immediate owner. Checks on
    /// OU-scoped infrastructure inherit access up the OU chain.
    var checkNode: IAMNode {
        switch self {
        case .organization(let id):
            return IAMNode(type: .organization, id: id)
        case .organizationalUnit(let id):
            return IAMNode(type: .organizationalUnit, id: id)
        }
    }

    var organizationID: UUID? {
        if case .organization(let id) = self { return id }
        return nil
    }

    var organizationalUnitID: UUID? {
        if case .organizationalUnit(let id) = self { return id }
        return nil
    }

    /// The root organization: the org itself, or the OU's owning organization.
    /// Nil only for a dangling OU reference.
    func rootOrganizationID(on db: PostgresStoreContext) async throws -> UUID? {
        switch self {
        case .organization(let id):
            return id
        case .organizationalUnit(let id):
            return try await OrganizationalUnit.find(id, on: db)?.organizationID
        }
    }

    func rootOrganizationID(using hierarchy: HierarchyPersistence) async throws -> UUID? {
        switch self {
        case .organization(let id):
            return id
        case .organizationalUnit(let id):
            return try await hierarchy.organizationalUnit(id: id)?.organizationalUnit.organizationID
        }
    }

    /// Builds a scope from a request's optional org/OU fields, enforcing the
    /// one-of invariant. `required: false` allows both-nil (returns nil);
    /// both-set is always an error.
    static func from(
        organizationID: UUID?,
        organizationalUnitID: UUID?,
        required: Bool = true
    ) throws -> OrganizationScope? {
        switch (organizationID, organizationalUnitID) {
        case (.some, .some):
            throw Abort(
                .badRequest,
                reason: "Provide either organizationId or organizationalUnitId, not both")
        case (.some(let org), .none):
            return .organization(org)
        case (.none, .some(let ou)):
            return .organizationalUnit(ou)
        case (.none, .none):
            guard !required else {
                throw Abort(.badRequest, reason: "Either organizationId or organizationalUnitId is required")
            }
            return nil
        }
    }

    /// Whether this scope contains `other`: an organization contains every
    /// scope rooted in it; an OU contains itself and its descendant OUs (an
    /// OU never contains org-level scopes — capacity delegated to an OU must
    /// not absorb org-wide resources without an explicit rescope).
    func contains(_ other: OrganizationScope, on db: PostgresStoreContext) async throws -> Bool {
        switch self {
        case .organization(let orgID):
            return try await other.rootOrganizationID(on: db) == orgID
        case .organizationalUnit(let ouID):
            guard case .organizationalUnit(let otherOUID) = other else { return false }
            // Walk the other OU's ancestry; bounded by OU nesting depth.
            var current: UUID? = otherOUID
            while let currentID = current {
                if currentID == ouID { return true }
                current = try await OrganizationalUnit.find(currentID, on: db)?.parentOUID
            }
            return false
        }
    }

    func contains(
        _ other: OrganizationScope,
        using hierarchy: HierarchyPersistence
    ) async throws -> Bool {
        switch self {
        case .organization(let organizationID):
            return try await other.rootOrganizationID(using: hierarchy) == organizationID
        case .organizationalUnit(let organizationalUnitID):
            guard case .organizationalUnit(let otherID) = other else { return false }
            let ancestors = try await hierarchy.organizationalUnitAncestors(id: otherID)
            return otherID == organizationalUnitID
                || ancestors.contains { $0.id == organizationalUnitID }
        }
    }

    /// Resolves and validates the referenced parent, failing the request with
    /// a client error when it doesn't exist (a typo'd id must not silently
    /// mint an unowned resource).
    func validateExists(on db: PostgresStoreContext) async throws {
        switch self {
        case .organization(let id):
            guard try await Organization.find(id, on: db) != nil else {
                throw Abort(.badRequest, reason: "Organization \(id) does not exist")
            }
        case .organizationalUnit(let id):
            guard try await OrganizationalUnit.find(id, on: db) != nil else {
                throw Abort(.badRequest, reason: "Folder \(id) does not exist")
            }
        }
    }

    func validateExists(using hierarchy: HierarchyPersistence) async throws {
        switch self {
        case .organization(let id):
            guard try await hierarchy.organization(id: id) != nil else {
                throw Abort(.badRequest, reason: "Organization \(id) does not exist")
            }
        case .organizationalUnit(let id):
            guard try await hierarchy.organizationalUnit(id: id) != nil else {
                throw Abort(.badRequest, reason: "Folder \(id) does not exist")
            }
        }
    }
}
