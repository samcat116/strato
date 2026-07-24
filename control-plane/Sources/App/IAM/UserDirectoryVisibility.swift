import Fluent
import Foundation
import Vapor

/// Which user records a caller may see — the scoping question `GET /api/users`
/// asks, and the identity-plane counterpart to `ProjectVisibility` (issue #687).
///
/// It is the same narrow-then-decide split, for the same reason. Narrowing
/// derives, in SQL, the records the caller could conceivably reach and decides
/// nothing; every candidate that carries a row still goes through the ordinary
/// `user:read` check, so guardrail forbids, authored forbids, and conditioned
/// bindings land exactly as they do on `GET /api/users/:userID`.
///
/// What it replaced was a full-table fetch of every account in the
/// installation, each one then evaluated on its own — the shape `/api/vms` and
/// the project-scoped lists were already cured of.
///
/// Unlike the project case the narrowing here is *exact* rather than merely a
/// superset, and that is a property of the identity plane rather than of this
/// type: a `User` record is parentless (`IAMResourceTree.chain` for a user node
/// is the node itself), so nothing is ever `in` one. A role binding reaches a
/// user record only by hanging on that record — an org-level binding grants
/// nothing on the org's members — and the tier-1 `platform-user-self` permit
/// reaches exactly the caller's own record. Every other way in belongs to
/// `platform-system-admin`, which is why an admin is not narrowed at all.
struct UserDirectoryVisibility: Sendable {

    /// The user records to narrow the directory query to, or nil when no bound
    /// can be derived and the query must not be narrowed at all.
    ///
    /// Nil means "every account is a candidate", not "everything is visible":
    /// a system admin still has each record they see decided below, so a tier-2
    /// guardrail narrows an admin's directory the same way it narrows anyone's.
    let candidateUserIDs: [UUID]?

    // MARK: - Narrowing

    /// Resolve the caller's candidate user records.
    static func resolve(on req: Request) async throws -> UserDirectoryVisibility {
        guard let user = req.auth.get(User.self), let userID = user.id else {
            throw Abort(.unauthorized)
        }

        // Cached for the request (#686), and the same single `isSystemAdmin`
        // read outside the evaluator that `ProjectVisibility` documents: it can
        // only *skip* narrowing, never grant. An admin's reach is the tier-1
        // policy rather than a binding, so a bindings-derived candidate set
        // would be just their own record and would hide the directory the
        // evaluator allows.
        let facts = try await IAMUserFacts.load(userID: userID, cache: req.iamCache, on: req.db)
        guard !facts.isSystemAdmin else { return UserDirectoryVisibility(candidateUserIDs: nil) }

        // `platform-user-self`: the caller's own record, always a candidate.
        var candidates: Set<UUID> = [userID]
        candidates.formUnion(
            try await boundRecords(userID: userID, groupIDs: facts.groupIDs, on: req.db))
        guard let authored = try await authoredPermitRecords(on: req) else {
            // An authored permit whose reach cannot be bounded. Widening to "no
            // narrowing" is the only safe answer; every record it puts in front
            // of the evaluator is still decided there.
            return UserDirectoryVisibility(candidateUserIDs: nil)
        }
        candidates.formUnion(authored)

        return UserDirectoryVisibility(candidateUserIDs: Array(candidates))
    }

    /// The user records the caller's active role bindings hang on — theirs and
    /// their groups'.
    ///
    /// Deliberately unfiltered by role, and conditioned bindings deliberately
    /// kept: which actions a role carries is the compiled set's business, and
    /// re-reading that here would be the parallel authorization model this
    /// split exists to avoid. A binding whose role does not grant `user:read`
    /// costs one candidate that the evaluator then denies.
    private static func boundRecords(
        userID: UUID, groupIDs: [UUID], on db: any Database
    ) async throws -> Set<UUID> {
        var principals: [(IAMPrincipalType, UUID)] = [(.user, userID)]
        principals += groupIDs.map { (IAMPrincipalType.group, $0) }

        let bindings = try await RoleBinding.query(on: db)
            .group(.or) { anyPrincipal in
                for (type, id) in principals {
                    anyPrincipal.group(.and) { thisPrincipal in
                        thisPrincipal.filter(\.$principalType == type.rawValue)
                        thisPrincipal.filter(\.$principalID == id)
                    }
                }
            }
            .filter(\.$nodeType == IAMNodeType.user.rawValue)
            .active()
            .all()

        return Set(bindings.map(\.nodeID))
    }

    /// The user records authored permit policies (issue #606) could grant
    /// `user:read` on, or nil when one of them cannot be bounded.
    ///
    /// A reverse lookup cannot enumerate an authored policy's principals (the
    /// caveat `WhoCanService` reports for the same reason), so every enabled
    /// permit that could cover the action is assumed to reach this caller and
    /// its resource scope becomes a candidate. A scope naming anything but a
    /// user record is skipped rather than widened: a user is parentless, so a
    /// policy confined to a container can never reach one.
    ///
    /// Gated on the compiled set's own authored-policy count, which makes the
    /// gate exact rather than an optimisation: a policy this replica has not
    /// compiled yet cannot allow anything either.
    private static func authoredPermitRecords(on req: Request) async throws -> Set<UUID>? {
        let built = try await IAMDecisionEngine.compiledSet(req.application)
        guard built.authoredPolicyCount > 0 else { return [] }

        let policies = try await IAMPolicy.query(on: req.db)
            .filter(\.$enabled == true)
            .filter(\.$effect == IAMPolicyEffect.permit.rawValue)
            .all()

        var records: Set<UUID> = []
        for policy in policies {
            guard let id = policy.id,
                let shape = try? CedarAuthoredPolicyInspector.describe(
                    cedarText: policy.cedarText, policyID: PolicyDescriptor.policyID(id))
            else {
                // Unparseable text is not in the compiled set either, so it
                // grants nothing and needs no candidate.
                continue
            }
            guard shape.actionScope.couldMatch("user:read") else { continue }
            guard let scope = shape.resourceScope, let nodeType = scope.type.nodeType else { return nil }
            guard nodeType == .user else { continue }
            records.insert(scope.id)
        }
        return records
    }

    // MARK: - Deciding

    /// The records among `userIDs` the caller may actually read, decided by the
    /// evaluator in one batch (#687) — the residue the narrowing above
    /// deliberately leaves to it.
    func readableUsers(among userIDs: some Sequence<UUID>, on req: Request) async throws -> Set<UUID> {
        let nodes = Set(userIDs).map { IAMNode(type: .user, id: $0) }
        return Set(try await req.canFilter("user:read", on: nodes).map(\.id))
    }
}
