import Fluent
import Vapor

/// The org-or-OU owner shared by organization-scoped infrastructure resources
/// (agents, sites, registration tokens; logical networks join in a later
/// phase). Mirrors Project's parent model: exactly one of organization /
/// organizational unit, stored as two nullable FK columns with the one-of
/// invariant enforced in application code.
enum OrganizationScope: Equatable, Sendable {
    case organization(UUID)
    case organizationalUnit(UUID)

    /// The (resourceType, id) pair naming this scope's node in an
    /// authorization check — checks on scoped infrastructure evaluate against
    /// the *immediate* owner so OU-scoped resources inherit access up the OU
    /// chain.
    var checkResource: (type: String, id: UUID) {
        switch self {
        case .organization(let id):
            return ("organization", id)
        case .organizationalUnit(let id):
            return ("organizational_unit", id)
        }
    }

    /// The same node as `checkResource`, in the tree vocabulary the batched
    /// list-filtering path (`Request.canFilter`) speaks. The legacy pair above
    /// is what the per-item `req.can(_:on:id:)` sites still take.
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
    func rootOrganizationID(on db: Database) async throws -> UUID? {
        switch self {
        case .organization(let id):
            return id
        case .organizationalUnit(let id):
            return try await OrganizationalUnit.find(id, on: db)?.$organization.id
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
    func contains(_ other: OrganizationScope, on db: Database) async throws -> Bool {
        switch self {
        case .organization(let orgID):
            return try await other.rootOrganizationID(on: db) == orgID
        case .organizationalUnit(let ouID):
            guard case .organizationalUnit(let otherOUID) = other else { return false }
            // Walk the other OU's ancestry; bounded by OU nesting depth.
            var current: UUID? = otherOUID
            while let currentID = current {
                if currentID == ouID { return true }
                current = try await OrganizationalUnit.find(currentID, on: db)?.$parentOU.id
            }
            return false
        }
    }

    /// Resolves and validates the referenced parent, failing the request with
    /// a client error when it doesn't exist (a typo'd id must not silently
    /// mint an unowned resource).
    func validateExists(on db: Database) async throws {
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
}
