import Fluent
import Foundation
import Vapor

/// The effect of an authored policy, derived from its Cedar text (issue #606).
///
/// Unlike a guardrail (forbid-only) or a role (permit-only), an authored policy
/// may be either: an org/project admin can hand out a grant its subtree does
/// not otherwise carry, or set a ceiling of its own. The effect is never sent
/// by the client — it is read off the parsed policy and stored so the catalog,
/// who-can, and the UI can label a policy without re-parsing.
enum IAMPolicyEffect: String, Codable, Sendable, CaseIterable {
    case permit
    case forbid
}

/// An authored Cedar policy: a permit or forbid written directly in Cedar
/// policy language, owned by an organization or project and compiled into the
/// policy set alongside role permits and guardrail forbids (issue #606).
///
/// `cedar_text` is the source of truth. `effect` is derived from it on every
/// write. The only structural rule (v1) is containment: the policy's resource
/// scope must name an entity inside the owner's subtree, so an org/project
/// admin can only reach resources they already administer — `PolicyStore`
/// enforces that on write. The principal scope is unrestricted (an admin
/// decides who a grant reaches within their subtree, cross-org included).
///
/// Authored policies are policy-set state: every write happens inside
/// `PolicySetVersionService.withPolicySetChange`, like roles and guardrails.
///
/// As with `RoleBinding` and `Guardrail`, `owner_id` carries no foreign key —
/// it points at one of several owner tables, discriminated by `owner_type`.
/// Org/project delete cascades remove owned policies (`PolicyStore.deleteOwned`).
final class IAMPolicy: Model, @unchecked Sendable {
    static let schema = "iam_policies"

    @ID(key: .id)
    var id: UUID?

    /// Slug, unique per owner. It appears in who-can results and (via the
    /// compiled id `policy-<uuid>`) in decision logs, so it is user-facing
    /// prose, not an internal handle.
    @Field(key: "name")
    var name: String

    @OptionalField(key: "description")
    var description: String?

    /// `organization` or `project` — there is no platform-owned authored
    /// policy, and the write API refuses one.
    @Field(key: "owner_type")
    var ownerType: String

    @Field(key: "owner_id")
    var ownerID: UUID

    /// The policy in Cedar policy language. Compiled into the policy set
    /// verbatim under the id `policy-<row uuid>`.
    @Field(key: "cedar_text")
    var cedarText: String

    /// `permit` or `forbid`, derived from `cedar_text` on every write. Never
    /// edited independently.
    @Field(key: "effect")
    var effect: String

    /// Disabled policies stay in the table but are left out of the compiled
    /// set. A policy gets switched off to unblock an incident far more often
    /// than it gets deleted, and the row is the audit trail of what was in
    /// force.
    @Field(key: "enabled")
    var enabled: Bool

    /// The user who created the policy.
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
        ownerType: IAMRoleOwnerType,
        ownerID: UUID,
        cedarText: String,
        effect: IAMPolicyEffect,
        enabled: Bool = true,
        createdBy: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.ownerType = ownerType.rawValue
        self.ownerID = ownerID
        self.cedarText = cedarText
        self.effect = effect.rawValue
        self.enabled = enabled
        self.createdBy = createdBy
    }
}

extension IAMPolicy {
    /// The typed owner type, or nil for a stored discriminator we do not know.
    var owner: IAMRoleOwnerType? {
        IAMRoleOwnerType(rawValue: ownerType)
    }

    /// The typed effect, or nil for a stored discriminator we do not know.
    var policyEffect: IAMPolicyEffect? {
        IAMPolicyEffect(rawValue: effect)
    }
}
