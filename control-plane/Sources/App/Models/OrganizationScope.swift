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

    /// The SpiceDB subject for a `#parent` relation, written against the
    /// *immediate* parent so OU-scoped resources inherit access up the OU
    /// chain (same rationale as `Project.spiceDBParentRef`).
    var spiceDBParentRef: (subjectType: String, subjectId: UUID) {
        switch self {
        case .organization(let id):
            return ("organization", id)
        case .organizationalUnit(let id):
            return ("organizational_unit", id)
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
                throw Abort(.badRequest, reason: "Organizational unit \(id) does not exist")
            }
        }
    }
}
