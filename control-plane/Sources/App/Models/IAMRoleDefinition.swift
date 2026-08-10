import Fluent
import Foundation
import Vapor

/// Who owns a role definition. Platform rows are the seeded defaults
/// (managed by `RoleRegistrySync`, immutable via the API); organization- and
/// project-owned rows are user-created and bindable at or below their owner.
/// A `organizational_unit` case can join later without a schema change —
/// the column is a plain string.
enum IAMRoleOwnerType: String, Codable, Sendable, CaseIterable {
    case platform
    case organization
    case project

    /// The IAM tree node type an owner scopes to; nil for platform rows,
    /// which apply everywhere.
    var nodeType: IAMNodeType? {
        switch self {
        case .platform: return nil
        case .organization: return .organization
        case .project: return .project
        }
    }

    /// The owner ids on `chain` that a role of this type may be bound at or
    /// below — nil for platform rows, which have no owner node and are
    /// bindable everywhere.
    ///
    /// The one place ownership containment is expressed: `RoleStore.bindable`
    /// filters the listing with it and `MemberRoleResolver` validates a by-id
    /// grant against it, so the roles a node offers and the roles it accepts
    /// cannot answer differently (STR-111 review). Both derive from
    /// `nodeType`'s exhaustive switch, so a new owner type is a compile error
    /// there rather than a role that binds by id but vanishes from the picker.
    func ownerIDs(along chain: [IAMNode]) -> [UUID]? {
        guard let nodeType else { return nil }
        return chain.filter { $0.type == nodeType }.map(\.id)
    }
}

/// A role definition: a named Cedar permit whose action scope is an explicit,
/// enumerable action list (issue #604). One machinery for every role — the
/// four defaults are seeded rows with fixed ids (`IAMRole.seededID`), not a
/// separate class.
///
/// `cedar_text` is the source of truth for what the role grants; `actions` is
/// derived from it on every write (and by `RoleRegistrySync` for managed
/// rows) so catalog/who-can/UI lookups stay plain queries.
///
/// Role definitions are policy-set state: every write happens inside
/// `PolicySetVersionService.withPolicySetChange`. Role *bindings* stay data
/// read per-request and never bump the version.
///
/// There is deliberately no foreign key on `owner_id`: platform rows use the
/// zero-UUID sentinel (`IAMRoleDefinition.platformOwnerID`) and org/project
/// owners follow the same polymorphic-pointer convention as `role_bindings`.
/// Bindings referencing a role deleted out from under them (org-delete
/// cascade) are dangling UUID ids that every read path drops — a harmless
/// under-grant.
final class IAMRoleDefinition: Model, @unchecked Sendable {
    static let schema = "iam_roles"

    /// Owner sentinel for platform rows. A real value (not NULL) so the
    /// `(owner_type, owner_id, name)` uniqueness holds — NULLs are distinct
    /// in unique indexes.
    static let platformOwnerID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @OptionalField(key: "description")
    var description: String?

    @Field(key: "owner_type")
    var ownerType: String

    @Field(key: "owner_id")
    var ownerID: UUID

    /// The role's permit, in Cedar policy language. Compiled into the policy
    /// set verbatim under the id `role-<row uuid>`.
    @Field(key: "cedar_text")
    var cedarText: String

    /// The action list derived from `cedar_text`'s action scope. Never edited
    /// independently.
    @Field(key: "actions")
    var actions: [String]

    /// Managed rows are the seeded defaults: reconciled from
    /// `IAMRoleRegistry` at boot, rejected by the write API.
    @Field(key: "managed")
    var managed: Bool

    /// The user who created the role; nil for seeded rows.
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
        actions: [String],
        managed: Bool = false,
        createdBy: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.ownerType = ownerType.rawValue
        self.ownerID = ownerID
        self.cedarText = cedarText
        self.actions = actions
        self.managed = managed
        self.createdBy = createdBy
    }
}

extension IAMRole {
    /// Fixed, well-known row ids for the seeded roles — identical on every
    /// deployment, so migrations can backfill `role_bindings.role_id` by
    /// constant and code can reference "the admin role" without a lookup.
    var seededID: UUID {
        switch self {
        case .viewer: return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        case .operator: return UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        case .editor: return UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        case .admin: return UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        }
    }

    /// The seeded role for a well-known id, nil for user-created roles.
    init?(seededID: UUID) {
        guard let role = IAMRole.allCases.first(where: { $0.seededID == seededID }) else { return nil }
        self = role
    }
}
