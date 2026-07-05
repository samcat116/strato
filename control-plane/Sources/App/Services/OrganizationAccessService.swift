import Foundation
import Vapor
import Fluent

/// Centralized organization- and project-scoped access checks shared by controllers.
///
/// These consolidate the `verifyOrganizationAccess` / `verifyOrganizationAdminAccess`
/// (and project-scoped) helpers that were previously copy-pasted across
/// `HierarchyController`, `GroupController`, `ResourceQuotaController`,
/// `OrganizationalUnitController`, and `ProjectController`. Behavior and error
/// messages are preserved exactly.
///
/// - Note: `OIDCController` deliberately keeps its own request-based variants: they
///   grant access to system admins and use different error messages, so they are not
///   interchangeable with the membership-only checks here.
struct OrganizationAccessService {
    /// Throws `.forbidden` unless the user is a member of the organization.
    static func requireMember(user: User, organizationID: UUID, on db: Database) async throws {
        guard let userID = user.id else {
            throw Abort(.unauthorized)
        }

        let userOrg = try await UserOrganization.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$organization.$id == organizationID)
            .first()

        guard userOrg != nil else {
            throw Abort(.forbidden, reason: "Not a member of this organization")
        }
    }

    /// Throws `.forbidden` unless the user is an admin of the organization.
    static func requireAdmin(user: User, organizationID: UUID, on db: Database) async throws {
        guard let userID = user.id else {
            throw Abort(.unauthorized)
        }

        let userOrg = try await UserOrganization.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$organization.$id == organizationID)
            .first()

        guard let userOrganization = userOrg, userOrganization.role == "admin" else {
            throw Abort(.forbidden, reason: "Admin access required")
        }
    }

    /// Resolves the project's root organization and requires membership.
    static func requireProjectMember(user: User, project: Project, on db: Database) async throws {
        let orgID = try await rootOrganizationID(of: project, on: db)
        try await requireMember(user: user, organizationID: orgID, on: db)
    }

    /// Resolves the project's root organization and requires admin role.
    static func requireProjectAdmin(user: User, project: Project, on db: Database) async throws {
        let orgID = try await rootOrganizationID(of: project, on: db)
        try await requireAdmin(user: user, organizationID: orgID, on: db)
    }

    private static func rootOrganizationID(of project: Project, on db: Database) async throws -> UUID {
        guard let orgID = try await project.getRootOrganizationId(on: db) else {
            throw Abort(.internalServerError, reason: "Project has no organization")
        }
        return orgID
    }
}
