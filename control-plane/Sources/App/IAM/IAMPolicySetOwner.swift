import Fluent
import Vapor

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

    var node: IAMNode {
        // Every creatable owner type has a node type; the platform sentinel is
        // refused before this is reached.
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
        guard IAMRoleOwnerType.creatable.contains(type) else {
            throw kind.uncreatableOwnerType(type.rawValue)
        }
        self.init(type: type, id: id, kind: kind)
    }

    /// Parse an owner off the wire, refusing a type this API cannot own.
    init(type: String, id: String, kind: Kind) throws {
        guard let ownerType = IAMRoleOwnerType(rawValue: type),
            IAMRoleOwnerType.creatable.contains(ownerType)
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
