import ControlPlanePostgres
import Foundation
import Vapor

/// Which projects a caller may see — the scoping question the project-scoped
/// list endpoints (`/api/volumes`, `/api/networks`, `/api/security-groups`,
/// `/api/floating-ips`) ask when the request names no `project_id` (issue #688).
///
/// Answering it is two steps, and the split between them is the whole design:
///
/// 1. **Narrow, in SQL.** From the caller's own grants, derive the projects
///    they could conceivably reach: the containers their role bindings hang on,
///    and the resource scopes of the authored permit policies in the compiled
///    set. This is a *superset* by construction and is only ever permitted to
///    be one — it exists to keep the row query off projects the caller has no
///    path to, and decides nothing.
/// 2. **Decide, in the evaluator.** Every candidate project that actually
///    carries rows goes through the ordinary `view_project` check. Cedar has
///    the last word, so guardrail and authored forbids, conditioned bindings,
///    roles this replica has not compiled yet, and truncated ancestor chains
///    all land exactly as they do on the item routes.
///
/// What this replaced was four copy-pasted `getAccessibleProjects` helpers that
/// loaded **every project in the installation** and ran a full evaluation
/// against each — `1 + P × ~7` queries before the endpoint's own query, with
/// `P` the platform-wide project count. Deriving the set in pure SQL instead
/// would be cheaper still, but it would be a second authorization model living
/// next to the evaluator, agreeing with it only by prose: it would miss the
/// ceilings that neutralise a real grant (a guardrail forbid, an authored
/// forbid), and it would honour bindings the entity-slice loader deliberately
/// skips. The narrow-then-decide split keeps one model and pays only for the
/// projects the caller could plausibly see.
///
/// The remaining per-candidate evaluations are one decision each, and this type
/// is the intended first consumer of the batch decision entry point (issue
/// #687): when it lands, `readableProjects` becomes a single batched call and
/// the whole resolution is O(1) queries.
struct ProjectVisibility: Sendable {

    /// The projects to narrow a row query to, or nil when no bound can be
    /// derived and the query must not be narrowed at all.
    ///
    /// Nil means "every project is a candidate", not "everything is visible":
    /// a system admin, whom `platform-system-admin` allows everywhere, still
    /// has each project they see decided below — a tier-2 guardrail narrows an
    /// admin's list the same way it narrows anyone's.
    let candidateProjectIDs: [UUID]?

    /// True when narrowing found nothing: no project is reachable, so a
    /// project-scoped list has no rows to return and need not query at all.
    var reachesNoProject: Bool { candidateProjectIDs?.isEmpty ?? false }

    // MARK: - Narrowing

    static func resolve(
        on req: Request,
        using iam: IAMPersistence,
        projects: ProjectsPersistence
    ) async throws -> ProjectVisibility {
        guard let user = req.auth.get(User.self), let userID = user.id else {
            throw Abort(.unauthorized)
        }
        guard let facts = try await iam.userAuthorizationFacts(ids: [userID]).first else {
            throw Abort(.unauthorized)
        }
        guard !facts.isSystemAdmin else { return ProjectVisibility(candidateProjectIDs: nil) }

        let subjects = [IAMOwnerReference(type: IAMPrincipalType.user.rawValue, id: userID)]
            + facts.groupIDs.map {
                IAMOwnerReference(type: IAMPrincipalType.group.rawValue, id: $0)
            }
        let bindings = try await iam.activeBindings(forSubjects: subjects)
        var containers = Set(
            bindings.compactMap { binding -> IAMNode? in
                guard let type = IAMNodeType(rawValue: binding.nodeType),
                    [.organization, .organizationalUnit, .project].contains(type)
                else { return nil }
                return IAMNode(type: type, id: binding.nodeID)
            }
        )
        guard let authored = try await authoredPermitContainers(on: req, using: iam) else {
            return ProjectVisibility(candidateProjectIDs: nil)
        }
        containers.formUnion(authored)
        return ProjectVisibility(
            candidateProjectIDs: try await projects.candidateProjectIDs(
                organizationIDs: containers.filter { $0.type == .organization }.map(\.id),
                organizationalUnitIDs: containers.filter { $0.type == .organizationalUnit }.map(\.id),
                projectIDs: containers.filter { $0.type == .project }.map(\.id)
            )
        )
    }

    private static func authoredPermitContainers(
        on req: Request,
        using iam: IAMPersistence
    ) async throws -> Set<IAMNode>? {
        let built = try await IAMDecisionEngine.compiledSet(req.application)
        guard built.authoredPolicyCount > 0 else { return [] }

        var containers: Set<IAMNode> = []
        for policy in try await iam.allEnabledPolicies()
        where policy.effect == IAMPolicyEffect.permit.rawValue {
            guard
                let shape = try? CedarAuthoredPolicyInspector.describe(
                    cedarText: policy.cedarText,
                    policyID: PolicyDescriptor.policyID(policy.id)
                )
            else { continue }
            guard shape.actionScope.couldMatch("project:read") else { continue }
            guard let scope = shape.resourceScope, let nodeType = scope.type.nodeType else {
                return nil
            }
            guard [.organization, .organizationalUnit, .project].contains(nodeType) else {
                continue
            }
            containers.insert(IAMNode(type: nodeType, id: scope.id))
        }
        return containers
    }

    // MARK: - Deciding

    /// The projects among `projectIDs` the caller may actually read, decided by
    /// the evaluator in one batch (#687).
    ///
    /// This is the residue the SQL narrowing above deliberately leaves to the
    /// evaluator, so it is exactly the shape batching exists for: one decision
    /// per surviving project, all of them sharing a single entity-slice load.
    ///
    /// `project:read` is what the item routes' `view_project` translates to, and
    /// the request memo is keyed on the *translated* action — so a list-scoping
    /// decision and the object check that follows it remain the same question,
    /// answered once (#686).
    func readableProjects(
        among projectIDs: some Sequence<UUID>, on req: Request
    ) async throws -> Set<UUID> {
        let nodes = Set(projectIDs).map { IAMNode(type: .project, id: $0) }
        return Set(try await req.canFilter("project:read", on: nodes).map(\.id))
    }

    /// The rows whose project the caller may read.
    func readableRows<Row>(
        _ rows: [Row], projectID: (Row) -> UUID, on req: Request
    ) async throws -> [Row] {
        let readable = try await readableProjects(among: rows.map(projectID), on: req)
        return rows.filter { readable.contains(projectID($0)) }
    }
}
