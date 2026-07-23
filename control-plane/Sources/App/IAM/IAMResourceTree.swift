import Fluent
import Foundation
import Vapor

/// A node in the org/resource tree: the `(type, id)` pair a role binding
/// attaches to.
struct IAMNode: Content, Hashable, Sendable {
    let type: IAMNodeType
    let id: UUID

    init(type: IAMNodeType, id: UUID) {
        self.type = type
        self.id = id
    }

    /// Parse a wire `(resourceType, resourceId)` pair into a tree node. An
    /// unknown type is a `400`, not a `403` — naming a type that does not
    /// exist is a malformed request, not a denied one.
    init(resourceType: String, resourceId: String) throws {
        guard let type = IAMNodeType(rawValue: resourceType) else {
            throw Abort(.badRequest, reason: "Unknown resource type '\(resourceType)'")
        }
        guard let id = UUID(uuidString: resourceId) else {
            throw Abort(.badRequest, reason: "Resource id must be a UUID")
        }
        self.init(type: type, id: id)
    }
}

/// Walks the resource tree upward. Role bindings attach to any node — an
/// individual resource, its project, a folder in the chain, or the org — and
/// apply to everything beneath, so answering either "can this principal?" or
/// "who can?" starts by resolving the chain from a node to its organization.
///
/// The design's one-parent invariant (docs/architecture/iam.md) is what keeps
/// this a walk rather than a graph search: every node has at most one parent,
/// so the chain is a list.
enum IAMResourceTree {
    /// Guards against a parent cycle introduced by corrupt data. The real tree
    /// is org → folder* → project → resource; anything beyond this is a bug,
    /// and truncating beats looping forever inside a request.
    private static let maxDepth = 64

    /// The chain from `node` up to its organization, `node` first.
    ///
    /// A node whose parent cannot be resolved simply ends the chain — a
    /// dangling id, or a project attached to neither a folder nor an org.
    /// Callers degrade to the bindings they can see rather than failing: a
    /// truncated chain can only under-report access, never invent it.
    static func ancestors(of node: IAMNode, on db: any Database) async throws -> [IAMNode] {
        var chain: [IAMNode] = [node]
        var seen: Set<IAMNode> = [node]
        var cursor = node

        while chain.count < maxDepth {
            guard let next = try await parent(of: cursor, on: db) else { break }
            guard seen.insert(next).inserted else { break }
            chain.append(next)
            cursor = next
        }
        return chain
    }

    /// The single parent of a node, or nil at the root (or when the parent
    /// cannot be resolved).
    static func parent(of node: IAMNode, on db: any Database) async throws -> IAMNode? {
        switch node.type {
        case .organization:
            return nil

        case .user:
            // A user record is parentless by construction: users belong to
            // organizations as a *set* (`memberOfOrgs` on the principal
            // entity), and the tree's one-parent invariant cannot express
            // that. Access to a user record comes from the two tier-1
            // policies instead of from anything inherited.
            return nil

        case .organizationalUnit:
            guard let ou = try await OrganizationalUnit.find(node.id, on: db) else { return nil }
            if let parentOUID = ou.$parentOU.id {
                return IAMNode(type: .organizationalUnit, id: parentOUID)
            }
            return IAMNode(type: .organization, id: ou.$organization.id)

        case .project:
            guard let project = try await Project.find(node.id, on: db) else { return nil }
            if let ouID = project.$organizationalUnit.id {
                return IAMNode(type: .organizationalUnit, id: ouID)
            }
            if let orgID = project.$organization.id {
                return IAMNode(type: .organization, id: orgID)
            }
            return nil

        case .virtualMachine:
            guard let vm = try await VM.find(node.id, on: db) else { return nil }
            return IAMNode(type: .project, id: vm.$project.id)

        case .sandbox:
            guard let sandbox = try await Sandbox.find(node.id, on: db) else { return nil }
            return IAMNode(type: .project, id: sandbox.$project.id)

        case .image:
            guard let image = try await Image.find(node.id, on: db) else { return nil }
            return IAMNode(type: .project, id: image.$project.id)

        case .volume:
            guard let volume = try await Volume.find(node.id, on: db) else { return nil }
            return IAMNode(type: .project, id: volume.$project.id)

        case .volumeSnapshot:
            guard let snapshot = try await VolumeSnapshot.find(node.id, on: db) else { return nil }
            // A snapshot references its volume by attribute, not as a parent
            // (docs/architecture/iam.md) — its container is the project.
            return IAMNode(type: .project, id: snapshot.$project.id)

        case .sandboxSnapshot:
            guard let snapshot = try await SandboxSnapshot.find(node.id, on: db) else { return nil }
            return IAMNode(type: .project, id: snapshot.$project.id)

        case .network:
            guard let network = try await LogicalNetwork.find(node.id, on: db) else { return nil }
            if let projectID = network.$project.id {
                return IAMNode(type: .project, id: projectID)
            }
            // A site-scoped network has no project; it inherits from whichever
            // org or folder owns the site's capacity.
            guard let siteID = network.$site.id else { return nil }
            return try await parent(of: IAMNode(type: .site, id: siteID), on: db)

        case .floatingIP:
            guard let floatingIP = try await FloatingIP.find(node.id, on: db) else { return nil }
            return IAMNode(type: .project, id: floatingIP.$project.id)

        case .securityGroup:
            guard let group = try await SecurityGroup.find(node.id, on: db) else { return nil }
            return IAMNode(type: .project, id: group.$project.id)

        case .site:
            guard let site = try await Site.find(node.id, on: db) else { return nil }
            return scopeNode(ouID: site.$organizationalUnit.id, orgID: site.$organization.id)

        case .agent:
            guard let agent = try await Agent.find(node.id, on: db) else { return nil }
            return scopeNode(ouID: agent.$organizationalUnit.id, orgID: agent.$organization.id)

        case .serviceAccount:
            guard let account = try await ServiceAccount.find(node.id, on: db) else { return nil }
            return IAMNode(type: .project, id: account.$project.id)
        }
    }

    /// Sites and agents are dedicated to exactly one of an org or a folder
    /// (`OrganizationScope`), so the two ids are mutually exclusive.
    private static func scopeNode(ouID: UUID?, orgID: UUID?) -> IAMNode? {
        if let ouID { return IAMNode(type: .organizationalUnit, id: ouID) }
        if let orgID { return IAMNode(type: .organization, id: orgID) }
        return nil
    }
}
