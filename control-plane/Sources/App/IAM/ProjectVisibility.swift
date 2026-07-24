import Fluent
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

    /// Resolve the caller's candidate projects.
    static func resolve(on req: Request) async throws -> ProjectVisibility {
        guard let user = req.auth.get(User.self), let userID = user.id else {
            throw Abort(.unauthorized)
        }

        // Cached for the request (#686): every check this endpoint goes on to
        // make reads the same facts.
        let facts = try await IAMUserFacts.load(userID: userID, cache: req.iamCache, on: req.db)
        // The one `isSystemAdmin` read outside the evaluator that is not a
        // widening (docs/architecture/iam.md): an admin's reach is the tier-1
        // policy, not a binding, so a bindings-derived candidate set would be
        // *empty* and would hide rows the evaluator allows. Skipping the
        // narrowing can only put more projects in front of `req.can`, and
        // every one of them is still decided there — which is what keeps a
        // tier-2 guardrail able to narrow an admin's list.
        guard !facts.isSystemAdmin else { return ProjectVisibility(candidateProjectIDs: nil) }

        var containers = try await bindingContainers(
            userID: userID, groupIDs: facts.groupIDs, on: req.db)
        guard let authored = try await authoredPermitContainers(on: req) else {
            // An authored permit whose reach cannot be bounded. Widening to
            // "no narrowing" is the only safe answer; the evaluator still
            // decides every project the rows land in.
            return ProjectVisibility(candidateProjectIDs: nil)
        }
        containers.formUnion(authored)

        return ProjectVisibility(candidateProjectIDs: try await projects(under: containers, on: req.db))
    }

    /// The org, folder, and project nodes the caller's active role bindings
    /// hang on — theirs and their groups'.
    ///
    /// Deliberately unfiltered by role: which actions a role carries is the
    /// compiled set's business, and narrowing here on a second reading of the
    /// role rows would be exactly the parallel model this type avoids. A
    /// binding whose role does not grant `project:read` costs one candidate
    /// that the evaluator then denies. Conditioned bindings are kept for the
    /// same reason — the slice loader skips them (under-granting), and a
    /// superset must not anticipate that.
    ///
    /// Bindings on individual resources (a VM, a volume) are not containers:
    /// they grant on that resource, and nothing above it, so they make no
    /// project visible.
    private static func bindingContainers(
        userID: UUID, groupIDs: [UUID], on db: any Database
    ) async throws -> Set<IAMNode> {
        var principals: [(IAMPrincipalType, UUID)] = [(.user, userID)]
        principals += groupIDs.map { (IAMPrincipalType.group, $0) }

        let containerTypes: [IAMNodeType] = [.organization, .organizationalUnit, .project]
        let bindings = try await RoleBinding.query(on: db)
            .group(.or) { anyPrincipal in
                for (type, id) in principals {
                    anyPrincipal.group(.and) { thisPrincipal in
                        thisPrincipal.filter(\.$principalType == type.rawValue)
                        thisPrincipal.filter(\.$principalID == id)
                    }
                }
            }
            .filter(\.$nodeType ~~ containerTypes.map(\.rawValue))
            .active()
            .all()

        return Set(
            bindings.compactMap { binding in
                IAMNodeType(rawValue: binding.nodeType).map { IAMNode(type: $0, id: binding.nodeID) }
            })
    }

    /// The containers authored permit policies (issue #606) could grant
    /// `project:read` inside, or nil when one of them cannot be bounded.
    ///
    /// A reverse lookup cannot enumerate an authored policy's principals (the
    /// caveat `WhoCanService` reports for the same reason), so every enabled
    /// permit that could cover the action is assumed to reach this caller and
    /// its resource scope is added as a candidate container. The scope is
    /// always a concrete node — `PolicyStore` refuses an unscoped `resource` on
    /// write — so this widens by a bounded amount rather than to the fleet.
    ///
    /// Gated on the compiled set's own authored-policy count, which is also
    /// what makes the gate exact rather than an optimisation: a policy this
    /// replica has not compiled yet cannot allow anything either, so skipping
    /// the query when the set has none can never drop a grant Cedar would make.
    private static func authoredPermitContainers(on req: Request) async throws -> Set<IAMNode>? {
        let built = try await IAMDecisionEngine.compiledSet(req.application)
        guard built.authoredPolicyCount > 0 else { return [] }

        let policies = try await IAMPolicy.query(on: req.db)
            .filter(\.$enabled == true)
            .filter(\.$effect == IAMPolicyEffect.permit.rawValue)
            .all()

        var containers: Set<IAMNode> = []
        for policy in policies {
            guard let id = policy.id,
                let shape = try? CedarAuthoredPolicyInspector.describe(
                    cedarText: policy.cedarText, policyID: PolicyDescriptor.policyID(id))
            else {
                // Unparseable text is not in the compiled set either, so it
                // grants nothing and needs no candidate.
                continue
            }
            guard shape.actionScope.couldMatch("project:read") else { continue }
            guard let scope = shape.resourceScope, let nodeType = scope.type.nodeType else { return nil }
            guard [.organization, .organizationalUnit, .project].contains(nodeType) else {
                // A scope pinned to a resource below a project cannot permit
                // reading the project itself.
                continue
            }
            containers.insert(IAMNode(type: nodeType, id: scope.id))
        }
        return containers
    }

    /// Every project inside the given containers: the projects named directly,
    /// plus those hanging off the organizations and folders (folder subtrees
    /// included, via the materialized `path`).
    private static func projects(under containers: Set<IAMNode>, on db: any Database) async throws -> [UUID] {
        let organizationIDs = containers.filter { $0.type == .organization }.map(\.id)
        let folderIDs = containers.filter { $0.type == .organizationalUnit }.map(\.id)
        let projectIDs = containers.filter { $0.type == .project }.map(\.id)
        guard !organizationIDs.isEmpty || !folderIDs.isEmpty || !projectIDs.isEmpty else { return [] }

        // A project belongs to exactly one of an organization or a folder
        // (`Project.validate`), so reaching an org's projects means reaching
        // its folders' too. One query collects both: every folder in a
        // candidate org, and every folder at or beneath a candidate folder —
        // the `path` (`/orgId/ouId/…/selfId`) contains a folder's own id, so
        // the prefix match covers the folder itself.
        var descendantFolderIDs: [UUID] = []
        if !organizationIDs.isEmpty || !folderIDs.isEmpty {
            descendantFolderIDs = try await OrganizationalUnit.query(on: db)
                .group(.or) { anyFolder in
                    if !organizationIDs.isEmpty {
                        anyFolder.filter(\.$organization.$id ~~ organizationIDs)
                    }
                    for folderID in folderIDs {
                        anyFolder.filter(\.$path ~~ folderID.uuidString)
                    }
                }
                .all()
                .compactMap(\.id)
        }
        let allFolderIDs = Array(Set(folderIDs).union(descendantFolderIDs))

        return try await Project.query(on: db)
            .group(.or) { anyProject in
                if !organizationIDs.isEmpty {
                    anyProject.filter(\.$organization.$id ~~ organizationIDs)
                }
                if !allFolderIDs.isEmpty {
                    anyProject.filter(\.$organizationalUnit.$id ~~ allFolderIDs)
                }
                if !projectIDs.isEmpty {
                    anyProject.filter(\.$id ~~ projectIDs)
                }
            }
            .all()
            .compactMap(\.id)
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
