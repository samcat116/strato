import Fluent
import Foundation
import Vapor

/// A role grant: `principal` holds `role` on `node` (an org-tree node or an
/// individual resource), optionally conditioned and optionally expiring.
///
/// This table is the policy store for the Cedar-based evaluator (see
/// docs/architecture/iam.md) — what grants evaluate from since the cutover
/// (issue #482). Rows are written in the same database transaction as the
/// mutation they accompany wherever one exists.
///
/// There is deliberately no foreign key on `node_id`: the column points at
/// many tables (discriminated by `node_type`), same as `ResourceOperation`.
final class RoleBinding: Model, @unchecked Sendable {
    static let schema = "role_bindings"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "principal_type")
    var principalType: String

    @Field(key: "principal_id")
    var principalID: UUID

    /// The granted role, as the `iam_roles` row id in `UUID.uuidString`
    /// (uppercase) form. A string column rather than a typed uuid because
    /// the table's five-column unique constraint predates role-row identity
    /// and SQLite cannot drop a unique table constraint without a rebuild.
    /// Rows whose value parses to no known role are dropped by every read
    /// path (under-grant, never over-grant).
    @Field(key: "role")
    var role: String

    @Field(key: "node_type")
    var nodeType: String

    @Field(key: "node_id")
    var nodeID: UUID

    /// Optional condition from the fixed vocabulary (`mfa`, `ip_range`,
    /// `tags`/`environment`), stored as a JSON document. Unused in phase 1;
    /// the column exists so conditioned bindings need no schema change.
    @OptionalField(key: "condition")
    var condition: String?

    /// TTL of the grant. A nil value never expires. Every read path must
    /// exclude expired rows (`.active()`).
    @OptionalField(key: "expires_at")
    var expiresAt: Date?

    /// The user who wrote the grant; nil for system-written rows (backfills).
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
        condition: String? = nil,
        expiresAt: Date? = nil,
        createdBy: UUID? = nil
    ) {
        self.id = id
        self.principalType = principalType.rawValue
        self.principalID = principalID
        self.role = roleID.uuidString
        self.nodeType = nodeType.rawValue
        self.nodeID = nodeID
        self.condition = condition
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
        condition: String? = nil,
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
            condition: condition,
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
