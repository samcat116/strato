import Fluent
import Foundation
import Vapor

/// Validates a hand-authored guardrail forbid and holds it to the guardrail
/// shape (#610).
///
/// Guardrails now accept two inputs, the same way roles do (`actions` XOR
/// `cedarText`, issue #605): the fixed matcher vocabulary — the builder — or a
/// forbid an admin writes directly. This is the second path. Where an authored
/// *policy* (`PolicyStore`) may be a permit or a forbid scoped anywhere inside
/// its owner, an authored *guardrail* is held tighter, because it is still a
/// tier-2 ceiling:
///
///   - **forbid-only** — a permit here would be a grant wearing a ceiling's
///     clothes, exactly what the matcher path refuses;
///   - **contained to the attach node** — the forbid's resource scope must name
///     the attach node or a resource inside it, so a ceiling only reaches the
///     subtree it hangs on (the same containment `PolicyStore` gives an authored
///     policy, but the target is the attach node, not an owner);
///   - **not self-locking** — an *unconditional* forbid that could reach
///     `iam:setPolicy` for everyone would outlaw its own removal, the same rule
///     the matcher path enforces structurally.
///
/// The candidate is compiled against the live schema so Cedar's own errors are a
/// `400` at write time rather than a row the compiled-set cache silently drops
/// at boot — the same treatment `RoleStore` and `PolicyStore` give stored text.
enum GuardrailText {

    /// The Cedar text a write will store, after it is proven to hold the shape.
    struct Prepared: Equatable, Sendable {
        let cedarText: String
    }

    /// The compiled-set id an authored guardrail's stored text is parsed under —
    /// `guardrail-<row uuid>`, the same id the matcher path embeds, so a denial
    /// names the ceiling and the cache can pre-screen the row.
    static func policyID(_ guardrailID: UUID) -> String {
        "guardrail-\(guardrailID.uuidString.lowercased())"
    }

    /// Validate `cedarText` as a guardrail forbid contained inside `attachNode`.
    static func prepare(
        cedarText: String,
        guardrailID: UUID,
        attachNode: IAMNode,
        engine: any CedarEngine,
        on db: any Database
    ) async throws -> Prepared {
        let trimmed = cedarText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GuardrailError.emptyCedarText }

        let id = policyID(guardrailID)
        let shape = try CedarAuthoredPolicyInspector.describe(cedarText: trimmed, policyID: id)

        guard shape.effect == .forbid else {
            throw GuardrailError.authoredMustForbid(shape.effect.rawValue)
        }
        try await requireContained(shape, attachNode: attachNode, on: db)
        try validateNotSelfLocking(shape)
        try await compileCandidate(policyID: id, cedarText: trimmed, engine: engine, on: db)

        return Prepared(cedarText: trimmed)
    }

    /// Prove the forbid's resource scope names the attach node or a resource
    /// inside it — a ceiling reaches only the subtree it hangs on.
    ///
    /// Mirrors `PolicyStore.requireContained`, but the containment target is the
    /// attach node rather than an owner, and there is no owner-type gate because
    /// `GuardrailStore.attachableNodeTypes` already fixed it upstream.
    private static func requireContained(
        _ shape: AuthoredPolicyShape, attachNode: IAMNode, on db: any Database
    ) async throws {
        guard let scope = shape.resourceScope else {
            throw GuardrailError.authoredUnscopedResource
        }
        guard let scopeNodeType = scope.type.nodeType else {
            throw GuardrailError.authoredPrincipalResourceScope(scope.type.rawValue)
        }
        let resourceNode = IAMNode(type: scopeNodeType, id: scope.id)
        let chain = try await IAMResourceTree.ancestors(of: resourceNode, on: db)
        guard chain.contains(attachNode) else {
            throw GuardrailError.authoredOutOfScope(
                attach: "\(attachNode.type.rawValue)/\(attachNode.id)",
                resource: "\(scope.type.rawValue)/\(scope.id)")
        }
    }

    /// Refuse the one unremovable ceiling: an *unconditional* forbid over
    /// `iam:setPolicy` for every principal.
    ///
    /// Structural and deliberately conservative — it fires only on the clearest
    /// self-lock (unconstrained principal, no `when`/`unless`, an action scope
    /// that could reach `iam:setPolicy`). A cleverly conditioned forbid can
    /// still fence out policy administration, but a guardrail is managed by
    /// admins of its attach node *or any container above it*, so a lower one is
    /// always removable from above; only one at the organization root is truly
    /// stuck, and that is the case this catches most directly. The matcher path
    /// keeps its own exact check for matcher-built rows.
    private static func validateNotSelfLocking(_ shape: AuthoredPolicyShape) throws {
        guard !shape.principalConstrained, !shape.hasConditions,
            shape.actionScope.couldMatch(GuardrailStore.policyWriteAction)
        else { return }
        throw GuardrailError.locksOutPolicyAdministration
    }

    /// Compile the candidate against the schema the store would have — the same
    /// per-policy validation `CedarPolicySetCache` runs at boot, so a forbid
    /// that only fails against the live schema is caught here.
    private static func compileCandidate(
        policyID: String, cedarText: String, engine: any CedarEngine, on db: any Database
    ) async throws {
        let roles = try await RoleStore.allDescriptors(on: db)
        let schemaText = CedarSchemaBuilder.schemaText(roles: roles)
        let source = CedarPolicySource(id: policyID, text: cedarText)
        if let issue = engine.policyIssue(schemaText: schemaText, policy: source) {
            throw GuardrailError.rejectedByCedar(issue)
        }
    }
}
