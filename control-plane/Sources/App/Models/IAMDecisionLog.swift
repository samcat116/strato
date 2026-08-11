import Fluent
import Vapor

/// One authorization decision (IAM phase 4, issue #481) — the first-class
/// decision log distinct from the mutation audit trail: `audit_events` records
/// what HTTP happened; this records what was *decided* — the canonical action
/// and node, the verdict, the deciding policy, the policy-set
/// version, and the tier that produced the outcome. This is what makes
/// guardrail denials debuggable and later feeds the policy simulator.
///
/// No foreign keys on purpose: decisions must outlive the users and resources
/// they describe, exactly like the audit trail.
/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class IAMDecisionLog: Model, @unchecked Sendable {
    static let schema = "iam_decision_logs"

    @ID(key: .id)
    var id: UUID?

    /// Vapor's per-request id, correlating the decisions of one request with
    /// each other and with the request log.
    @OptionalField(key: "request_id")
    var requestID: String?

    @OptionalField(key: "path")
    var path: String?

    @OptionalField(key: "method")
    var method: String?

    /// The subject as passed to the check — a user UUID everywhere today,
    /// kept as a string so an unexpected subject shape is still logged.
    @Field(key: "subject")
    var subject: String

    /// The canonical IAM action (`vm:read`, …). Nil only for denials on
    /// node-less platform and identity surfaces that never enter Cedar.
    @OptionalField(key: "action")
    var action: String?

    @OptionalField(key: "node_type")
    var nodeType: String?

    @OptionalField(key: "node_id")
    var nodeID: UUID?

    /// The organization containing the checked node, from the slice's
    /// ancestor chain.
    @OptionalField(key: "organization_id")
    var organizationID: UUID?

    /// `allow` / `deny` — what actually gated the request — or
    /// `credential_restricted` for a restricted credential refused on a
    /// node-less surface that the evaluator does not gate.
    @Field(key: "decision")
    var decision: String

    /// JSON array of the policy ids that determined Cedar's decision
    /// (`role-editor`, `guardrail-<id>`, `platform-system-admin`, …).
    @OptionalField(key: "determining_policies")
    var determiningPoliciesJSON: String?

    /// The tier that produced Cedar's decision: `platform`, `guardrail`,
    /// `credential` (the request's own credential restriction, STR-115),
    /// `policy` (an authored permit/forbid, issue #606), `grant`, or
    /// `default-deny` — plus `unknown`, which is unreachable with today's
    /// policy ids and therefore means a new id prefix arrived without
    /// `CedarCheckDecision.tier` learning about it.
    @OptionalField(key: "tier")
    var tier: String?

    /// Cedar evaluation errors, or the load/translation failure detail.
    @OptionalField(key: "cedar_errors")
    var cedarErrors: String?

    /// The policy-set version the evaluated set was compiled from.
    @OptionalField(key: "policy_version")
    var policyVersion: Int?

    /// Conditioned bindings the slice skipped — a deny may be explained by a
    /// grant the loader deliberately would not flatten.
    @OptionalField(key: "skipped_conditioned_bindings")
    var skippedConditionedBindings: Int?

    /// The credential the request authenticated with — `api_key` or
    /// `cli_session` (STR-115). Nil for a browser session and for an agent's
    /// JWT-SVID. Recorded on allows too, so a decision log answers "what has
    /// this token been doing" and not only "what was it refused".
    @OptionalField(key: "credential_type")
    var credentialType: String?

    @OptionalField(key: "credential_id")
    var credentialID: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}
}

extension IAMDecisionLog {
    /// The decoded determining-policy ids.
    var determiningPolicies: [String] {
        guard let json = determiningPoliciesJSON,
            let data = json.data(using: .utf8),
            let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return ids
    }
}
