import ControlPlanePostgres
import Vapor

// The acting principal of a request (issue #495).
//
// Before JWT-SVIDs, every authenticated request was a user: sessions and API
// keys both resolve to a `User`, so `auth.get(User.self)` *was* the principal.
// Machine principals (service accounts, registered workloads) have been Cedar
// principals since #491 but had no way to present themselves on the HTTP API.
//
// This is the seam that generalizes the request path without generalizing the
// evaluator, which already takes an `IAMPrincipal`. Everything downstream —
// `req.can`, `req.authorize`, `req.canFilter`, the default-deny middleware —
// asks for the acting principal instead of the user.

extension Request {
    /// The principal acting on this request, or nil when unauthenticated.
    ///
    /// A user session or API key wins over a workload credential: if both are
    /// somehow present, the human identity is the more specific one and the one
    /// the audit trail already understands.
    var actingPrincipal: IAMPrincipal? {
        if let user = auth.get(User.self), let userID = user.id {
            return .user(userID)
        }
        return authenticatedWorkload?.principal
    }

    /// The acting principal, or `.unauthorized`.
    func requireActingPrincipal() throws -> IAMPrincipal {
        guard let principal = actingPrincipal else {
            throw Abort(.unauthorized, reason: "Not authenticated")
        }
        return principal
    }

    /// Reject a machine principal on a surface that structurally needs a human
    /// user record — the self-scoped identity plane (your API keys, your
    /// passkeys, your OAuth sessions), where "you" has no meaning for a service
    /// account.
    ///
    /// A 403 with a reason, not the bare 401 an `auth.require(User.self)` would
    /// produce: the credential authenticated fine, it just cannot act here.
    func requireActingUser(_ surface: String) throws -> User {
        if let user = auth.get(User.self) { return user }
        if isWorkloadAuthenticated {
            throw Abort(
                .forbidden,
                reason: "\(surface) is only available to user principals, not workload credentials")
        }
        throw Abort(.unauthorized, reason: "Not authenticated")
    }

    /// The organization a request's principal is scoped to, for the
    /// collection-level checks that ask "are you anyone in this org at all".
    ///
    /// Users carry a current organization on their record. Machine principals
    /// do not — they hold nothing by membership — so their scope comes from
    /// where they were registered: a service account's project's organization,
    /// or a workload registration's organization.
    func actingOrganizationID(
        workloads: WorkloadsPersistence,
        serviceAccounts: ServiceAccountsPersistence,
        projects: ProjectsPersistence
    ) async throws -> UUID? {
        if let user = auth.get(User.self) {
            return user.currentOrganizationId
        }
        guard let workload = authenticatedWorkload else { return nil }
        switch workload.resolved {
        case .agent:
            return nil
        case .serviceAccount(let id):
            guard let account = try await serviceAccounts.account(id: id),
                let project = try await projects.project(id: account.projectID)
            else { return nil }
            return project.rootOrganizationID
        case .workload(let id):
            return try await workloads.registration(id: id)?.organizationID
        }
    }
}
