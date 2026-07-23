import Foundation

// IAM authored policies (issue #606): an authored-policy row as the Cedar
// builders consume it, and the one place authored-policy compiled-id naming
// lives. `CedarPolicyAssembler` and `CedarPolicySetCache` derive the policy id
// through here so they cannot disagree — a mismatch would be a policy the
// decision log could never name.

/// An authored-policy row, engine- and database-free for testability.
struct PolicyDescriptor: Equatable, Sendable {
    let id: UUID
    let name: String
    /// The policy in Cedar policy language — compiled verbatim. Empty text
    /// compiles to nothing (the row is dropped from the set); an authored
    /// policy has no schema fields to keep declared, unlike a role.
    let cedarText: String

    /// The compiled policy id — what decision logs name. The `policy-` prefix
    /// is what `CedarCheckDecision.tier` keys "policy" on.
    var policyID: String { Self.policyID(id) }

    /// Cedar-side names use lowercased UUIDs, matching `CedarEntityUID`'s
    /// convention and the `role-`/`guardrail-` id shapes.
    static func policyID(_ id: UUID) -> String { "policy-\(id.uuidString.lowercased())" }

    init(id: UUID, name: String, cedarText: String) {
        self.id = id
        self.name = name
        self.cedarText = cedarText
    }
}

extension PolicyDescriptor {
    /// Descriptor for an authored-policy row. Nil when the row has no id
    /// (unsaved model), which cannot reach the compile path.
    init?(row: IAMPolicy) {
        guard let id = row.id else { return nil }
        self.init(id: id, name: row.name, cedarText: row.cedarText)
    }
}
