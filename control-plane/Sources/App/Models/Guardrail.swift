import Fluent
import Foundation
import Vapor

/// A tier-2 guardrail: a ceiling on what tier-3 grants can reach beneath a
/// tree node (docs/architecture/iam.md).
///
/// Guardrails attach to containers (org / folder / project), inherit downward,
/// and **intersect** — every ceiling in the ancestry chain applies, and a
/// nearer one never overrides a farther one. There is no "nearest wins" rule
/// because ceilings only subtract: letting a child node relax an ancestor's
/// ceiling would make it a grant, which is exactly what tier 2 must not be.
///
/// **The table stores forbids and nothing else.** `effect` exists so the row
/// says what it is rather than leaving it implied, but it is a constant: see
/// `GuardrailEffect`, which has one case, and the check constraint the
/// migration adds on Postgres.
///
/// As with `RoleBinding`, `node_id` carries no foreign key — it points at
/// several tables, discriminated by `node_type`.
final class Guardrail: Model, @unchecked Sendable {
    static let schema = "iam_guardrails"

    @ID(key: .id)
    var id: UUID?

    /// Slug, unique per attach node. It appears in the denial the write-time
    /// check produces (`403 GuardrailViolation … folder/engineering/no-prod-for-contractors`),
    /// so it is user-facing prose, not an internal handle.
    @Field(key: "name")
    var name: String

    /// Why the ceiling exists. A denial names the guardrail; this is what makes
    /// the name mean something to whoever hits it.
    @OptionalField(key: "description")
    var description: String?

    @Field(key: "node_type")
    var nodeType: String

    @Field(key: "node_id")
    var nodeID: UUID

    /// Always `forbid`. See the type note above.
    @Field(key: "effect")
    var effect: String

    /// Canonicalized action patterns: exact actions, `service:*`, or `*`.
    @Field(key: "actions")
    var actions: [String]

    @Field(key: "principal_match_kind")
    var principalMatchKind: String

    /// The user or group id, for the match kinds that name one.
    @OptionalField(key: "principal_match_id")
    var principalMatchID: UUID?

    @Field(key: "resource_match_kind")
    var resourceMatchKind: String

    /// The environment name, for the match kinds that carry a value.
    @OptionalField(key: "resource_match_value")
    var resourceMatchValue: String?

    /// Disabled guardrails stay in the table but stop applying. Ceilings get
    /// switched off to unblock an incident far more often than they get
    /// deleted, and the row is the audit trail of what was in force.
    @Field(key: "enabled")
    var enabled: Bool

    @OptionalField(key: "created_by")
    var createdBy: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        description: String? = nil,
        nodeType: IAMNodeType,
        nodeID: UUID,
        actions: [String],
        principalMatch: GuardrailPrincipalMatch,
        resourceMatch: GuardrailResourceMatch,
        enabled: Bool = true,
        createdBy: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.nodeType = nodeType.rawValue
        self.nodeID = nodeID
        self.effect = GuardrailEffect.forbid.rawValue
        self.actions = actions
        self.principalMatchKind = principalMatch.kind.rawValue
        self.principalMatchID = principalMatch.subjectID
        self.resourceMatchKind = resourceMatch.kind.rawValue
        self.resourceMatchValue = resourceMatch.value
        self.enabled = enabled
        self.createdBy = createdBy
    }
}

extension Guardrail {
    /// The node this ceiling hangs on. Nil only if the stored discriminator is
    /// not a type we know — an unreadable row, which `GuardrailStore` treats as
    /// a hard error rather than an absent ceiling.
    var node: IAMNode? {
        guard let type = IAMNodeType(rawValue: nodeType) else { return nil }
        return IAMNode(type: type, id: nodeID)
    }

    /// The typed principal-side constraint.
    func principalMatch() throws -> GuardrailPrincipalMatch {
        guard let kind = GuardrailPrincipalMatchKind(rawValue: principalMatchKind) else {
            throw GuardrailError.missingSubjectID(principalMatchKind)
        }
        return try GuardrailPrincipalMatch.from(kind: kind, subjectID: principalMatchID)
    }

    /// The typed resource-side constraint.
    func resourceMatch() throws -> GuardrailResourceMatch {
        guard let kind = GuardrailResourceMatchKind(rawValue: resourceMatchKind) else {
            throw GuardrailError.missingMatchValue(resourceMatchKind)
        }
        return try GuardrailResourceMatch.from(kind: kind, value: resourceMatchValue)
    }

    /// Which side of the forbid carries the constraint, for display. Both
    /// sides can be constrained at once ("contractors may not touch prod"),
    /// which is why this is derived rather than a stored discriminator that
    /// could disagree with the matches beside it.
    var shape: String {
        let principalConstrained = principalMatchKind != GuardrailPrincipalMatchKind.any.rawValue
        let resourceConstrained = resourceMatchKind != GuardrailResourceMatchKind.any.rawValue
        switch (principalConstrained, resourceConstrained) {
        case (true, true): return "principal+resource"
        case (true, false): return "principal"
        case (false, true): return "resource"
        case (false, false): return "unconditional"
        }
    }
}
