import Foundation
import Vapor
import Fluent

/// Centralized organization- and project-scoped access checks shared by controllers.
///
/// The Cedar evaluator is the single source of truth for authorization: these helpers
/// delegate to `Request.can` rather than reading organization membership metadata.
/// Role bindings are the authoritative grant representation.
///
/// Org- and project-scoped checks name canonical actions and typed IAM nodes,
/// which resolve org/OU inheritance
/// (and, once granted, project-level roles) through the schema.
///
/// - Note: `OIDCController` keeps its own request-based variants for their distinct
///   error messages, but since the issue #482 pre-cutover audit they authorize through
///   the same `req.can` path as these helpers.
struct OrganizationAccessService {
    /// Throws `.forbidden` unless the current user can view the organization.
    static func requireMember(organizationID: UUID, on req: Request) async throws {
        guard try await req.can("org:read", on: IAMNode(type: .organization, id: organizationID)) else {
            throw Abort(.forbidden, reason: "Not a member of this organization")
        }
    }

    /// `requireMember`, for a *narrowing parameter* rather than a gate (STR-203).
    ///
    /// The difference is what stands behind it. `requireMember` is often the
    /// only thing between a caller and an organization's contents; this one is
    /// followed, at every call site, by a per-row evaluator decision on the rows
    /// themselves — so `?organization_id=` can only ever remove rows the caller
    /// was already going to be shown. Enforcing a credential's ceiling against
    /// `org:read` here therefore protects nothing and costs a project-scoped
    /// token the ability to say which organization it means; the ceiling is
    /// applied per row, where there is an act to apply it to. Membership itself
    /// is still decided, so a non-member is refused exactly as before.
    ///
    /// Deliberately *not* what the other `requireMember` call sites use: most of
    /// them are the authorization, with nothing behind them to filter.
    static func requireMembershipForNarrowing(organizationID: UUID, on req: Request) async throws {
        guard
            try await req.canAsMembershipProbe(
                "org:read", on: IAMNode(type: .organization, id: organizationID))
        else {
            throw Abort(.forbidden, reason: "Not a member of this organization")
        }
    }

    /// Throws `.forbidden` unless the current user can manage the organization's members.
    static func requireAdmin(organizationID: UUID, on req: Request) async throws {
        guard try await req.can("org:update", on: IAMNode(type: .organization, id: organizationID)) else {
            throw Abort(.forbidden, reason: "Admin access required")
        }
    }

    /// Throws `.forbidden` unless the current user can view the project (via a direct
    /// project role, a group grant, or inherited org/OU membership).
    static func requireProjectMember(project: Project, on req: Request) async throws {
        let projectID = try project.requireID()
        guard try await req.can("project:read", on: IAMNode(type: .project, id: projectID)) else {
            throw Abort(.forbidden, reason: "Not a member of this organization")
        }
    }

    /// Throws `.forbidden` unless the current user can change project IAM policy (via a
    /// direct project admin role, a group admin grant, or inherited org/OU admin).
    ///
    /// Project metadata updates use `project:update`, which editors hold; IAM
    /// policy changes require the distinct administrative action below.
    static func requireProjectPolicyAdmin(project: Project, on req: Request) async throws {
        try await requireProjectAction("iam:setPolicy", project: project, on: req)
    }

    /// Throws `.forbidden` unless the current user may manage project quotas.
    static func requireProjectQuotaAdmin(project: Project, on req: Request) async throws {
        try await requireProjectAction("quota:manage", project: project, on: req)
    }

    /// Enforces a canonical IAM action against a project node.
    static func requireProjectAction(_ action: String, project: Project, on req: Request) async throws {
        let projectID = try project.requireID()
        guard try await req.can(action, on: IAMNode(type: .project, id: projectID)) else {
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
    /// entirely) can scope a list at all — and, since STR-203, so a credential
    /// restricted to a subtree can name the organization it is confined to
    /// instead of being refused for a permission the narrowing never used.
    static func organizationListFilter(on req: Request) async throws -> OrganizationListFilter? {
        guard let raw = req.query[String.self, at: "organization_id"] else { return nil }
        guard let organizationID = UUID(uuidString: raw) else {
            // Unlike the older `project_id` filters, a malformed id is rejected rather
            // than ignored: silently returning the unfiltered fleet is the failure mode
            // this filter exists to prevent.
            throw Abort(.badRequest, reason: "Invalid organization_id")
        }
        try await requireMembershipForNarrowing(organizationID: organizationID, on: req)
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
