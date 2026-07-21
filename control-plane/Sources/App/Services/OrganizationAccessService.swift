import Foundation
import Vapor
import Fluent

/// Centralized organization- and project-scoped access checks shared by controllers.
///
/// The Cedar evaluator is the single source of truth for authorization: these helpers
/// delegate to `Request.can` rather than reading the relational
/// `UserOrganization.role`. The relational role survives only as a display mirror
/// written alongside the authoritative role binding.
///
/// Org-scoped checks map to the `organization` object's `view_organization` /
/// `manage_members` permissions; project-scoped checks map to the `project` object's
/// `view_project` / `manage_project` permissions, which resolve org/OU inheritance
/// (and, once granted, project-level roles) through the schema.
///
/// - Note: `OIDCController` keeps its own request-based variants for their distinct
///   error messages, but since the issue #482 pre-cutover audit they authorize through
///   the same `req.can` path as these helpers.
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

    /// The `organization_id` narrowing filter for a list endpoint, resolved from the
    /// request's query string. Returns nil when the param is absent (list everything
    /// the caller can see).
    ///
    /// Narrowing is not authorization: the caller still gets only the rows their
    /// per-row permission check allows. This exists so a client that has picked an
    /// organization — the frontend's sidebar switcher — can ask for that org's rows
    /// instead of the whole fleet, and so system admins (who bypass the per-row check
    /// entirely) can scope a list at all.
    static func organizationListFilter(on req: Request) async throws -> OrganizationListFilter? {
        guard let raw = req.query[String.self, at: "organization_id"] else { return nil }
        guard let organizationID = UUID(uuidString: raw) else {
            // Unlike the older `project_id` filters, a malformed id is rejected rather
            // than ignored: silently returning the unfiltered fleet is the failure mode
            // this filter exists to prevent.
            throw Abort(.badRequest, reason: "Invalid organization_id")
        }
        try await requireMember(organizationID: organizationID, on: req)
        return OrganizationListFilter(
            organizationID: organizationID,
            organizationalUnitIDs: try await OrganizationalUnit.query(on: req.db)
                .filter(\.$organization.$id == organizationID)
                .all()
                .compactMap { $0.id }
        )
    }
}

/// An organization to narrow a list endpoint's results to, together with the OUs
/// rooted in it.
///
/// An organization contains every scope rooted in it, so filtering by one must match
/// OU-scoped rows as well as org-scoped ones (`OrganizationScope.contains`). Every OU
/// carries a direct `organization_id` regardless of nesting depth, so one query
/// collects the whole hierarchy — no path walk needed.
struct OrganizationListFilter: Sendable {
    let organizationID: UUID
    let organizationalUnitIDs: [UUID]

    /// Whether a resource with this scope belongs to the filtered organization.
    ///
    /// A nil scope is a row the org backfill never reached, not a shared resource, so
    /// it belongs to no organization and matches nothing.
    func contains(_ scope: OrganizationScope?) -> Bool {
        switch scope {
        case .organization(let id):
            return id == organizationID
        case .organizationalUnit(let id):
            return organizationalUnitIDs.contains(id)
        case nil:
            return false
        }
    }

    /// The projects in this organization's hierarchy — the bridge for resources that
    /// reach their org through a project (VMs, sandboxes) rather than owning a scope.
    func projectIDs(on db: any Database) async throws -> [UUID] {
        var projects = try await Project.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .all()
        if !organizationalUnitIDs.isEmpty {
            projects += try await Project.query(on: db)
                .filter(\.$organizationalUnit.$id ~~ organizationalUnitIDs)
                .all()
        }
        return projects.compactMap { $0.id }
    }
}
