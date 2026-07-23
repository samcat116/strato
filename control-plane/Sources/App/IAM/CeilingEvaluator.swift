import Fluent
import Foundation
import Vapor

/// Evaluates whether a **ceiling** (a guardrail or authored forbid) denies a
/// concrete request, against the compiled policy set, without recording a
/// decision-log row (#610).
///
/// `who-can` and `WhoCanService.can` enumerate *grants* cheaply from the tree,
/// but a grant is not the last word: a tier-2 guardrail forbid, or an authored
/// forbid policy, can subtract from it. Reflecting that is what makes their
/// answers agree with `IAMAuthorizer` — the difference between "who is granted"
/// and "who can actually act."
///
/// The query is always **concrete** (a fixed principal, action, and node), so
/// ordinary evaluation answers it exactly — the symbolic solver (#484) is only
/// needed for the subtree-quantified *write-time* check, where the resource is
/// not yet pinned. This reflects matcher-built guardrails, hand-authored
/// guardrails, and authored forbid policies through one path.
///
/// It calls the compiled artifact directly rather than `IAMAuthorizer.authorize`
/// on purpose: the authorizer records a decision-log row per call, and a
/// reverse-lookup pass over a bounded candidate set must not flood the log with
/// synthetic decisions.
enum CeilingEvaluator {

    /// The request principal for a who-can entry, or nil for a group — a group
    /// is not something that makes a request, so its members' own entries carry
    /// whether a ceiling reaches them.
    static func requestPrincipal(type: IAMPrincipalType, id: UUID) -> IAMPrincipal? {
        switch type {
        case .user: return .user(id)
        case .serviceAccount: return .serviceAccount(id)
        case .workload: return .workload(id)
        case .group: return nil
        }
    }

    /// The ceiling policy ids that deny `principal` performing `action` on
    /// `node`, or nil when the compiled set allows the request.
    ///
    /// For a principal who-can already found *granted*, a denial can only come
    /// from a forbid, so a non-nil result names the ceiling(s) in the way
    /// (`guardrail-<id>` / `policy-<id>`). A truncated ancestor chain is
    /// reported as a ceiling too, because the authorizer fails such a request
    /// closed — reporting access here would disagree with enforcement — via the
    /// internal `["chain-truncated"]` signal, which is a non-nil "denied" that
    /// names no policy; callers surfacing ids to the API filter it out (the
    /// entry stays ceilinged, its id list is empty).
    static func denyingCeilings(
        principal: IAMPrincipal,
        action: String,
        node: IAMNode,
        built: CedarPolicySetCache.Built,
        on db: any Database
    ) async throws -> [String]? {
        let slice = try await EntitySliceLoader.load(principal: principal, node: node, on: db)
        guard slice.chainComplete else { return ["chain-truncated"] }

        let decision = try built.artifact.authorize(
            principal: slice.principal,
            action: action,
            resource: slice.resource,
            context: slice.baseContextValue(roleIDs: built.roleIDs),
            entitiesJSON: slice.entitiesJSON())
        guard !decision.allowed else { return nil }

        let forbids = decision.determiningPolicyIDs.filter {
            $0.hasPrefix("guardrail-") || $0.hasPrefix("policy-")
        }
        // Denied, but not by a forbid: the slice did not see the grant who-can
        // enumerated from the bindings model — a conditioned binding it skips,
        // or a role this replica's set has not caught up to. That is a
        // divergence, not a ceiling, so do not report it as one.
        return forbids.isEmpty ? nil : forbids
    }
}
