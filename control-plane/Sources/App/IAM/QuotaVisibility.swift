import Foundation
import Vapor

/// Who may be told what a quota measures.
///
/// A quota row is not just a limit: `ResourceQuotaResponse` ships `usage` and
/// `utilization` off the stored counters, `/api/quotas/:id/usage` measures them
/// fresh with a per-VM breakdown, and `/resources/summary` derives per-quota
/// compliance. Those are all the same quantity — `QuotaEnforcementService`
/// writes the counters straight from `QuotaUsageAggregator.measure` — and for an
/// organization-scoped quota that quantity is *the organization's whole vCPU,
/// memory and VM consumption*.
///
/// So the quota is the scalar form of the inventory the hierarchy endpoints
/// filter per row (issue #870), and one gate has to cover every door onto it.
/// Gating one field or one route only moves the number: an earlier revision of
/// this work decided `quotaCompliance` on `quota:read` while the same figures
/// stayed reachable through the row DTO on three other endpoints and, fresher
/// still, through `/api/quotas/:id/usage`.
///
/// **`quota:read`, on the node the quota hangs on**, is that gate. It is
/// deliberately not the `org:read` / `view_organization` that admits the
/// *container*: bare org membership grants `org:read`, and the whole point is
/// that reaching a container is not reaching its contents. `quota:read` is
/// role-derived (the viewer group carries it), so a bare member does not hold
/// it, while anyone with a viewer role at organization level already sees the
/// rows the total is drawn from.
enum QuotaVisibility {

    /// The hierarchy node a quota's measurement covers, and therefore the node
    /// its read is decided on. Nil for a scopeless row.
    ///
    /// **The precedence here must mirror `QuotaUsageAggregator.projects(of:)`**
    /// — project, then folder, then organization — because that is what decides
    /// the rows the measurement actually sums. Resolving in any other order
    /// would gate a wide measurement on a narrow node, and nothing would fail:
    /// note that `QuotaComplianceService.quotaScope` and
    /// `ResourceQuotaResponse.init` both walk the *opposite* order for their own
    /// (purely descriptive) purposes, so copying either one here would be a
    /// silent under-gate.
    ///
    /// A scopeless row measures nothing — `QuotaUsageAggregator` resolves it to
    /// `.none` — and belongs to no organization, so it is nobody's to read here.
    /// The item routes keep it system-admin-only
    /// (`requireSystemAdminForScopelessQuota`); in a list it simply drops out,
    /// which is why a corrupt row can appear in an admin's quota list and not in
    /// their compliance figures.
    static func measuredNode(of quota: ResourceQuota) -> IAMNode? {
        if let projectID = quota.projectID { return IAMNode(type: .project, id: projectID) }
        if let folderID = quota.organizationalUnitID { return IAMNode(type: .organizationalUnit, id: folderID) }
        if let organizationID = quota.organizationID { return IAMNode(type: .organization, id: organizationID) }
        return nil
    }

    /// The quotas among `quotas` the caller may read, decided in one batch
    /// (#687) rather than one evaluation per row.
    static func readable(_ quotas: [ResourceQuota], on req: Request) async throws -> [ResourceQuota] {
        let readable = try await req.canFilter("quota:read", on: quotas.compactMap(measuredNode))
        return quotas.filter { measuredNode(of: $0).map(readable.contains) ?? false }
    }

    /// Whether the caller may read this one quota — the item-route form of
    /// ``readable(_:on:)``.
    ///
    /// A scopeless row has no node to decide on and returns false; callers fall
    /// back to their system-admin gate for that case.
    static func canRead(_ quota: ResourceQuota, on req: Request) async throws -> Bool {
        guard let node = measuredNode(of: quota) else { return false }
        return try await req.can("quota:read", on: node)
    }
}
