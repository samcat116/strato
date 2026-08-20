import Foundation

/// Who owns a role definition. Platform rows are the seeded defaults
/// (managed by `RoleRegistrySync`, immutable via the API); organization- and
/// project-owned rows are user-created and bindable at or below their owner.
/// A `organizational_unit` case can join later without a schema change —
/// the column is a plain string.
enum IAMRoleOwnerType: String, Codable, Sendable, CaseIterable {
    case platform
    case organization
    case project

    /// Owner sentinel for platform rows. A real value (not NULL) keeps the
    /// `(owner_type, owner_id, name)` uniqueness exact for seeded roles.
    static let platformOwnerID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

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
