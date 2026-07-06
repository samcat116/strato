import Foundation
import Vapor
import Fluent

/// Centralized organization- and project-scoped access checks shared by controllers.
///
/// SpiceDB is the single source of truth for authorization: these helpers delegate to
/// `Request.can` (which applies the system-admin bypass and calls SpiceDB) rather than
/// reading the relational `UserOrganization.role`. The relational role survives only as
/// a display mirror written alongside the SpiceDB tuple.
///
/// Org-scoped checks map to the `organization` object's `view_organization` /
/// `manage_members` permissions; project-scoped checks map to the `project` object's
/// `view_project` / `manage_project` permissions, which resolve org/OU inheritance
/// (and, once granted, project-level roles) through the schema.
///
/// - Note: `OIDCController` deliberately keeps its own request-based variants: they
///   use different error messages and semantics, so they are not interchangeable.
struct OrganizationAccessService {
    /// Throws `.forbidden` unless the current user can view the organization.
    static func requireMember(organizationID: UUID, on req: Request) async throws {
        guard try await req.can("view_organization", on: "organization", id: organizationID.uuidString) else {
            throw Abort(.forbidden, reason: "Not a member of this organization")
        }
    }

    /// Throws `.forbidden` unless the current user can manage the organization's members.
    static func requireAdmin(organizationID: UUID, on req: Request) async throws {
        guard try await req.can("manage_members", on: "organization", id: organizationID.uuidString) else {
            throw Abort(.forbidden, reason: "Admin access required")
        }
    }

    /// Throws `.forbidden` unless the current user can view the project (via a direct
    /// project role, a group grant, or inherited org/OU membership).
    static func requireProjectMember(project: Project, on req: Request) async throws {
        let projectID = try project.requireID()
        guard try await req.can("view_project", on: "project", id: projectID.uuidString) else {
            throw Abort(.forbidden, reason: "Not a member of this organization")
        }
    }

    /// Throws `.forbidden` unless the current user can manage the project (via a direct
    /// project admin role, a group admin grant, or inherited org/OU admin).
    static func requireProjectAdmin(project: Project, on req: Request) async throws {
        let projectID = try project.requireID()
        guard try await req.can("manage_project", on: "project", id: projectID.uuidString) else {
            throw Abort(.forbidden, reason: "Admin access required")
        }
    }
}
