import Fluent
import Vapor

/// The one authorization evaluator: every concrete "may principal P perform
/// action A on node N?" is decided here, by the compiled Cedar policy set over
/// the principal's entity slice.
///
/// Callers differ in what they do with the decision, not in how it is made.
/// `IAMAuthorizer` enforces it — wrapping the decision in a span, recording a
/// decision-log row, failing the request. `WhoCanService` reports it — the
/// arbitrary-principal `can` answer and the per-entry `ceilinged` marks of a
/// who-can enumeration. Before this seam existed those callers answered the
/// same question from different models (the compiled set vs. a hand-walked
/// bindings model), kept in agreement only by prose and a cross-check test —
/// and a drift between them was a security bug. Deciding through one function
/// removes the second model entirely.
///
/// Deliberately record-free: reporting callers evaluate bounded candidate
/// sets, and flooding the decision log with synthetic rows would bury the real
/// decisions. Recording is the enforcement caller's job.
enum IAMDecisionEngine {

    /// A denial made before evaluation, because evaluating would be unsound
    /// (`truncatedChain`) or impossible (`inapplicableAction`).
    enum StructuralDenial: Sendable {
        /// The ancestor chain never reached an organization — denied without
        /// evaluation, because a guardrail anchored above the break could not
        /// have applied (see `CedarEntitySlice.chainComplete`).
        case truncatedChain
        /// The schema does not apply this action to the resource's type, so
        /// no real request can ever pose the question (the middleware and
        /// translator only emit schema-applicable pairs) and the engine would
        /// refuse it as invalid. Query surfaces can still ask — the answer is
        /// the fail-closed "no", not a 500.
        case inapplicableAction
    }

    /// A decided check: the Cedar verdict plus the entity slice it was decided
    /// over. The slice carries what reporting and recording callers need — the
    /// ancestor chain (for the decision log's organization) and the
    /// skipped-conditioned-bindings count.
    struct Decision: Sendable {
        let verdict: CedarCheckDecision
        let slice: CedarEntitySlice
        /// Non-nil when the verdict is a structural fail-closed denial rather
        /// than an evaluation.
        let structuralDenial: StructuralDenial?

        var deniedForTruncatedChain: Bool { structuralDenial == .truncatedChain }

        /// The ceiling policy ids (`guardrail-<id>` / `policy-<id>`) that deny
        /// this check, or nil when no ceiling is in the way — the
        /// interpretation who-can uses to mark a granted-but-neutralised
        /// principal (#610).
        ///
        /// Nil covers three shapes: allowed; denied for an inapplicable action
        /// (nothing forbids — the question does not exist in the schema); and
        /// denied *but not by a forbid* — the slice did not see the grant the
        /// bindings table shows (a conditioned binding it skips, or a role
        /// this replica's set has not caught up to), which is a divergence to
        /// report as absence, not a ceiling. Empty (non-nil) is the
        /// truncated-chain denial: the check is denied and stays denied, but
        /// no policy names it.
        var denyingCeilingIDs: [String]? {
            switch structuralDenial {
            case .truncatedChain: return []
            case .inapplicableAction: return nil
            case nil: break
            }
            guard !verdict.allowed else { return nil }
            let forbids = verdict.determiningPolicyIDs.filter {
                $0.hasPrefix("guardrail-") || $0.hasPrefix("policy-")
            }
            return forbids.isEmpty ? nil : forbids
        }
    }

    /// The compiled artifact could not evaluate the check. Thrown instead of a
    /// verdict — never a silent allow, never a silent deny that would look
    /// like policy. Enforcement translates this to a logged 500.
    struct EvaluationFailure: Error {
        let underlying: any Error
    }

    /// This replica's compiled policy set, or a 503 when there is none. Boot
    /// builds the set before serving; reaching the guard means every rebuild
    /// since has failed and there was never a good one. Denying with 403 would
    /// look like policy — say what it is. One helper so enforcement and
    /// reporting fail closed identically: a who-can that silently degraded to
    /// a weaker model would be exactly the drift this module exists to end.
    static func compiledSet(_ app: Application) async throws -> CedarPolicySetCache.Built {
        guard let built = await app.cedarPolicySet.current else {
            app.logger.error("IAM check with no compiled Cedar policy set; failing closed")
            throw Abort(.serviceUnavailable, reason: "Authorization system is not ready")
        }
        return built
    }

    /// Decide "may `principal` perform `action` on `node`?" against `built`.
    ///
    /// Two questions are denied without evaluation (`structuralDenial`):
    ///
    /// - An action the schema does not apply to the node's resource type. No
    ///   real request can pose it (the middleware and translator only emit
    ///   schema-applicable pairs), and evaluating it would be a
    ///   request-validation error — but the query surfaces (who-can, the
    ///   arbitrary-principal check) accept caller-supplied pairs, and their
    ///   answer is the fail-closed "no", not a 500.
    /// - A truncated ancestor chain, which is fail-*open* for tier-2
    ///   guardrails — a forbid anchored above the break silently stops
    ///   matching while an in-chain binding still permits — so a loud
    ///   structural denial is diagnosis, not disruption. It binds system
    ///   admins too (letting them through would evade the very ceilings the
    ///   guard protects); repair goes through the admin-only hierarchy
    ///   validate/repair surface, which gates on `requireSystemAdmin` rather
    ///   than a per-object check.
    static func decide(
        principal: IAMPrincipal,
        action: String,
        node: IAMNode,
        built: CedarPolicySetCache.Built,
        on db: any Database
    ) async throws -> Decision {
        let slice = try await EntitySliceLoader.load(principal: principal, node: node, action: action, on: db)

        guard CedarSchemaBuilder.resourceTypes(for: action).contains(node.type.cedarEntityType) else {
            return Decision(
                verdict: CedarCheckDecision(
                    allowed: false,
                    determiningPolicyIDs: [],
                    evaluationErrors: [
                        "action \(action) does not apply to resource type \(node.type.rawValue); denied without evaluation (fail closed)"
                    ]),
                slice: slice,
                structuralDenial: .inapplicableAction)
        }

        guard slice.chainComplete else {
            return Decision(
                verdict: CedarCheckDecision(
                    allowed: false,
                    determiningPolicyIDs: [],
                    evaluationErrors: [
                        "ancestor chain truncated; denied without evaluation (fail closed)"
                    ]),
                slice: slice,
                structuralDenial: .truncatedChain)
        }

        let verdict: CedarCheckDecision
        do {
            verdict = try built.artifact.authorize(
                principal: slice.principal,
                action: action,
                resource: slice.resource,
                context: slice.baseContextValue(roleIDs: built.roleIDs),
                entitiesJSON: slice.entitiesJSON())
        } catch {
            throw EvaluationFailure(underlying: error)
        }
        return Decision(verdict: verdict, slice: slice, structuralDenial: nil)
    }
}
