import Fluent
import Vapor

/// What a policy-set row's owner type means to the API and the database, kept
/// with the owner rather than on the wire enum in `IAMRoleDefinition`: the enum
/// declares the stored vocabulary, and this is the behaviour roles and authored
/// policies read off it.
extension IAMRoleOwnerType {
    /// The owner types a create may name. Platform rows are the deployment's
    /// own policy — the seeded defaults reconciled by `RoleRegistrySync` and the
    /// tier-1 permits, which are code — so nothing creates one over HTTP, and a
    /// request that asks to is told so rather than having its owner quietly
    /// coerced.
    static let creatableOwners: Set<IAMRoleOwnerType> = [.organization, .project]

    /// Whether an owner of this type with this id is a row that exists.
    ///
    /// The single place the owner types are resolved to tables: roles and
    /// authored policies both refuse an owner that isn't there, and a new owner
    /// type joining the enum has exactly one switch to answer for. Platform is
    /// never a real row — it is the zero-UUID sentinel
    /// (`IAMRoleDefinition.platformOwnerID`), not something an owner lookup can
    /// find — so it answers false and the caller's "no such owner" applies.
    func ownerExists(id: UUID, on db: any Database) async throws -> Bool {
        switch self {
        case .organization:
            return try await Organization.find(id, on: db) != nil
        case .project:
            return try await Project.find(id, on: db) != nil
        case .platform:
            return false
        }
    }
}

/// The owner of a policy-set row — a role definition (issue #605) or an
/// authored policy (issue #606) — as both halves it is used as: the store's
/// `(ownerType, ownerID)` pair and the tree node the gates run on.
///
/// One type for both APIs on purpose. They accept the same owners, resolve the
/// same node from them, and gate on that node the same way; the only thing
/// they disagree on is how a bad owner is worded, which `Kind` carries.
/// `IAMRoleOwnerType`'s comment anticipates an `organizational_unit` case
/// joining "without a schema change" — when it does, this is the one place
/// that has to learn about it, rather than two identical switches that nothing
/// keeps in sync.
struct IAMPolicySetOwner {
    /// Which policy-set API is asking. Everything below is shared behaviour;
    /// this is the per-API error vocabulary it reports through, so the shared
    /// checks throw the caller's own errors and the messages stay specific.
    enum Kind: Sendable {
        case role
        case policy

        /// The row this owner owns, singular and plural, for gate wording.
        var noun: String {
            switch self {
            case .role: return "role"
            case .policy: return "policy"
            }
        }

        var plural: String {
            switch self {
            case .role: return "roles"
            case .policy: return "policies"
            }
        }

        func uncreatableOwnerType(_ type: String) -> any Error {
            switch self {
            case .role: return RoleError.uncreatableOwnerType(type)
            case .policy: return PolicyError.uncreatableOwnerType(type)
            }
        }

        func unknownOwner(_ owner: String) -> any Error {
            switch self {
            case .role: return RoleError.unknownOwner(owner)
            case .policy: return PolicyError.unknownOwner(owner)
            }
        }

        var malformedOwnerID: any Error {
            switch self {
            case .role: return Abort(.badRequest, reason: "Role owner id must be a UUID")
            case .policy: return Abort(.badRequest, reason: "Policy owner id must be a UUID")
            }
        }
    }

    let type: IAMRoleOwnerType
    let id: UUID
    let kind: Kind

    /// The tree node the gates run on.
    ///
    /// Every creatable owner type has a node type, and the platform sentinel —
    /// which has none — never reaches here: the wire and create inits refuse
    /// it, and both `owner(of:)` readers screen it off a stored row before
    /// building one of these. The fallback is what an owner type added to the
    /// enum without a `nodeType` would degrade to, not a case in flight today.
    var node: IAMNode {
        IAMNode(type: type.nodeType ?? .organization, id: id)
    }

    init(type: IAMRoleOwnerType, id: UUID, kind: Kind) {
        self.type = type
        self.id = id
        self.kind = kind
    }

    /// The owner a create names, refusing a type this API cannot own — the
    /// typed counterpart of the wire-string init below, for a body that already
    /// decoded its owner type.
    init(creating type: IAMRoleOwnerType, id: UUID, kind: Kind) throws {
        guard IAMRoleOwnerType.creatableOwners.contains(type) else {
            throw kind.uncreatableOwnerType(type.rawValue)
        }
        self.init(type: type, id: id, kind: kind)
    }

    /// Parse an owner off the wire, refusing a type this API cannot own.
    init(type: String, id: String, kind: Kind) throws {
        guard let ownerType = IAMRoleOwnerType(rawValue: type),
            IAMRoleOwnerType.creatableOwners.contains(ownerType)
        else {
            throw kind.uncreatableOwnerType(type)
        }
        guard let ownerID = UUID(uuidString: id) else {
            throw kind.malformedOwnerID
        }
        self.init(type: ownerType, id: ownerID, kind: kind)
    }

    /// A row scoped to an owner that does not exist would be bindable and
    /// attributable nowhere, so this is a `404` at the boundary rather than an
    /// orphan row.
    func requireExists(on db: any Database) async throws {
        guard try await type.ownerExists(id: id, on: db) else {
            throw kind.unknownOwner("\(type.rawValue)/\(id)")
        }
    }

    /// Reading and writing a policy-set row is `iam:readPolicy` /
    /// `iam:setPolicy` on its owner — the same gate guardrails use, for the
    /// same reason: what a role or policy says is a statement about who can do
    /// what, not data inside the subtree.
    func requirePolicyAdmin(write: Bool, req: Request) async throws {
        guard try await req.can(write ? "iam:setPolicy" : "iam:readPolicy", on: node) else {
            throw Abort(
                .forbidden,
                reason: "Managing \(kind.plural) requires admin on the \(kind.noun)'s owner or a container above it")
        }
    }
}
