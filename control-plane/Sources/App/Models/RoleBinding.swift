import Fluent
import Foundation
import Vapor

/// A role grant: `principal` holds `roleID` on `node` (an org-tree node or an
/// individual resource), optionally expiring. Conditions are reserved, not
/// implemented — see `condition`.
///
/// This table is the policy store for the Cedar-based evaluator (see
/// docs/architecture/iam.md) — what grants evaluate from since the cutover
/// (issue #482). Rows are written in the same database transaction as the
/// mutation they accompany wherever one exists.
///
/// There is deliberately no foreign key on `node_id`: the column points at
/// many tables (discriminated by `node_type`), same as `ResourceOperation`.
/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class RoleBinding: Model, @unchecked Sendable {
    static let schema = "role_bindings"
    static let conditionConstraintName = "ck_role_bindings_condition_unsupported"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "principal_type")
    var principalType: String

    @Field(key: "principal_id")
    var principalID: UUID

    /// The granted `iam_roles` row id. The UUID column rejects role names and
    /// legacy membership literals at the persistence boundary.
    @Field(key: "role_id")
    var roleID: UUID

    @Field(key: "node_type")
    var nodeType: String

    @Field(key: "node_id")
    var nodeID: UUID

    /// Reserved for the fixed condition vocabulary (`mfa`, `ip_range`,
    /// `tags`/`environment`), to be stored as a JSON document.
    ///
    /// **Always nil.** Conditions are not implemented: nothing compiles one
    /// into the Cedar `when` clause, so `EntitySliceLoader` skips a conditioned
    /// binding entirely (fail-closed — it grants nothing, and looks live while
    /// doing so). A `CHECK (condition IS NULL)` constraint enforces that at the
    /// write boundary (`conditionConstraintName`, STR-108) and no
    /// initializer here can set one; the column stays so implementing them
    /// needs no schema change.
    @OptionalField(key: "condition")
    var condition: String?

    /// TTL of the grant. A nil value never expires. Every read path must
    /// exclude expired rows (`.active()`).
    @OptionalField(key: "expires_at")
    var expiresAt: Date?

    /// The user who wrote the grant; nil for system-written rows and migrations.
    @OptionalField(key: "created_by")
    var createdBy: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleID: UUID,
        nodeType: IAMNodeType,
        nodeID: UUID,
        expiresAt: Date? = nil,
        createdBy: UUID? = nil
    ) {
        self.id = id
        self.principalType = principalType.rawValue
        self.principalID = principalID
        self.roleID = roleID
        self.nodeType = nodeType.rawValue
        self.nodeID = nodeID
        self.expiresAt = expiresAt
        self.createdBy = createdBy
    }

    /// Convenience for the seeded roles, which most code paths grant.
    convenience init(
        id: UUID? = nil,
        principalType: IAMPrincipalType,
        principalID: UUID,
        role: IAMRole,
        nodeType: IAMNodeType,
        nodeID: UUID,
        expiresAt: Date? = nil,
        createdBy: UUID? = nil
    ) {
        self.init(
            id: id,
            principalType: principalType,
            principalID: principalID,
            roleID: role.seededID,
            nodeType: nodeType,
            nodeID: nodeID,
            expiresAt: expiresAt,
            createdBy: createdBy
        )
    }
}

extension RoleBinding: Content {}

extension QueryBuilder<RoleBinding> {
    /// Excludes expired bindings. Every path that *reads* bindings must apply
    /// this — `expires_at` is enforced at read time, not by a sweep.
    func active(at now: Date = Date()) -> Self {
        group(.or) { group in
            group.filter(\.$expiresAt == nil)
            group.filter(\.$expiresAt > now)
        }
    }
}
