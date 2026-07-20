import Fluent
import Vapor

/// One authorization decision (IAM phase 4, issue #481) — the first-class
/// decision log distinct from the mutation audit trail: `audit_events` records
/// what HTTP happened; this records what was *decided* — the permission
/// checked, both engines' verdicts, the deciding policy, the policy-set
/// version, and the tier that produced the outcome. This is what makes
/// guardrail denials debuggable and later feeds the policy simulator.
///
/// No foreign keys on purpose: decisions must outlive the users and resources
/// they describe, exactly like the audit trail.
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

    /// The SpiceDB subject as passed to the check — a user UUID everywhere
    /// today, kept as a string so an unexpected subject shape is still logged.
    @Field(key: "subject")
    var subject: String

    /// What SpiceDB was asked, verbatim.
    @Field(key: "spicedb_permission")
    var spicedbPermission: String

    @Field(key: "resource_type")
    var resourceType: String

    @Field(key: "resource_id")
    var resourceID: String

    /// The translated IAM action (`vm:read`, …); nil when the check has no
    /// faithful translation — those rows are the coverage gaps.
    @OptionalField(key: "iam_action")
    var iamAction: String?

    @OptionalField(key: "node_type")
    var nodeType: String?

    @OptionalField(key: "node_id")
    var nodeID: UUID?

    /// The organization containing the checked node, from the slice's
    /// ancestor chain — nil when translation or slice loading failed.
    @OptionalField(key: "organization_id")
    var organizationID: UUID?

    /// `allow` or `deny` — what actually gated the request.
    @Field(key: "spicedb_decision")
    var spicedbDecision: String

    /// `allow` / `deny`, or why there is no verdict: `untranslated` (no IAM
    /// mapping), `skipped` (no compiled policy set yet), `error` (evaluation
    /// failed).
    @Field(key: "cedar_decision")
    var cedarDecision: String

    /// Whether the two verdicts agree; nil when Cedar produced no verdict.
    /// The mismatch burn-down (docs/architecture/iam.md phase 4) queries this.
    @OptionalField(key: "decisions_match")
    var decisionsMatch: Bool?

    /// JSON array of the policy ids that determined Cedar's decision
    /// (`role-editor`, `guardrail-<id>`, `platform-system-admin`, …).
    @OptionalField(key: "determining_policies")
    var determiningPoliciesJSON: String?

    /// The tier that produced Cedar's decision: `platform`, `guardrail`,
    /// `grant`, or `default-deny` — plus `unknown`, which is unreachable with
    /// today's policy ids and therefore means a new id prefix arrived without
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
