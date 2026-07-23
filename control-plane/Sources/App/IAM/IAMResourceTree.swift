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

/// The IAM-relevant attributes of the node a walk started from, read off the
/// row the walk already loaded to find its parent.
///
/// Every one of these used to cost a second `find` of the same row further
/// down the check (`GuardrailStore.resourceEnvironment` and the slice loader's
/// network attributes both re-fetched the leaf). Harvesting them here is what
/// makes the walk the *only* read of the leaf — and it puts the "which types
/// carry an environment" question in one place: a new resource type with an
/// `environment` column that forgets to fill this in silently falls out of
/// every environment ceiling, so it is answered where the row is in hand.
struct IAMLeafFacts: Sendable, Equatable {
    /// The leaf's `environment` column, for the types that store one. Nil for
    /// the types that genuinely have none (environment is an attribute, never
    /// a container) and for a leaf whose row is missing.
    var environment: String?
    /// Network leaves only: whether the row named a project, and whether it
    /// named a site. Nil for any other type, and for a missing row — which
    /// callers must read as the closed answer (an unreadable network is not
    /// world-readable), never as "no project".
    var networkHasProject: Bool?
    var networkHasSite: Bool?
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

    /// A resolved chain plus the leaf attributes harvested on the way up.
    struct Resolution: Sendable, Equatable {
        let chain: [IAMNode]
        let leaf: IAMLeafFacts
    }

    /// The chain from `node` up to its organization, `node` first.
    ///
    /// A node whose parent cannot be resolved simply ends the chain — a
    /// dangling id, or a project attached to neither a folder nor an org.
    /// Callers degrade to the bindings they can see rather than failing: a
    /// truncated chain can only under-report access, never invent it.
    static func ancestors(of node: IAMNode, on db: any Database) async throws -> [IAMNode] {
        try await resolve(node, on: db).chain
    }

    /// `ancestors(of:)` plus the leaf's attributes — the form authorization
    /// checks use, so the leaf row is read exactly once per check.
    ///
    /// - Parameter cache: a request-scoped cache to answer from and populate.
    ///   Passing nil resolves against the database, which is what every
    ///   caller outside a request (background sweeps, tests) does.
    static func resolve(
        _ node: IAMNode, cache: IAMRequestCache? = nil, on db: any Database
    ) async throws -> Resolution {
        if let cached = cache?.chain(of: node) { return cached }
        let resolution = try await walk(from: node, on: db)
        cache?.store(chain: resolution, of: node)
        return resolution
    }

    private static func walk(from node: IAMNode, on db: any Database) async throws -> Resolution {
        // A folder leaf resolves its whole chain in the batched walk below;
        // starting there costs one query for any depth.
        if node.type == .organizationalUnit {
            return Resolution(
                chain: try await folderChain(from: node.id, limit: maxDepth, on: db), leaf: IAMLeafFacts())
        }

        var chain: [IAMNode] = [node]
        var seen: Set<IAMNode> = [node]
        var cursor = node
        var leaf = IAMLeafFacts()

        while chain.count < maxDepth {
            let step = try await self.step(from: cursor, on: db)
            if cursor == node { leaf = step.leaf }
            guard let next = step.parent else { break }
            // Everything above a folder is folders and then the organization,
            // so hand the rest of the walk to the batched resolver.
            if next.type == .organizationalUnit {
                chain += try await folderChain(from: next.id, limit: maxDepth - chain.count, on: db)
                break
            }
            guard seen.insert(next).inserted else { break }
            chain.append(next)
            cursor = next
        }
        return Resolution(chain: chain, leaf: leaf)
    }

    /// The chain from a folder up to its organization, folder first.
    ///
    /// The parent pointers stay authoritative: the materialized `path`
    /// (`/orgId/ouId/…/selfId`) is used only as a *prefetch hint*, pulling the
    /// rows this walk is about to need in one query instead of one per level.
    /// A stale or unparsable path therefore costs a query, never a wrong
    /// chain — which matters because the chain decides which bindings and
    /// which guardrails apply.
    private static func folderChain(from ouID: UUID, limit: Int, on db: any Database) async throws -> [IAMNode] {
        guard limit > 0, let first = try await OrganizationalUnit.find(ouID, on: db) else { return [] }

        var prefetched: [UUID: OrganizationalUnit] = [:]
        let hinted = first.ancestorAndSelfOUIDs().filter { $0 != ouID }
        if !hinted.isEmpty {
            for row in try await OrganizationalUnit.query(on: db).filter(\.$id ~~ hinted).all() {
                if let id = row.id { prefetched[id] = row }
            }
        }

        var chain: [IAMNode] = []
        var seen: Set<UUID> = []
        var cursor: OrganizationalUnit? = first
        while let ou = cursor, let id = ou.id, chain.count < limit, seen.insert(id).inserted {
            chain.append(IAMNode(type: .organizationalUnit, id: id))
            guard let parentOUID = ou.$parentOU.id else {
                if chain.count < limit {
                    chain.append(IAMNode(type: .organization, id: ou.$organization.id))
                }
                break
            }
            if let hit = prefetched[parentOUID] {
                cursor = hit
            } else {
                cursor = try await OrganizationalUnit.find(parentOUID, on: db)
            }
        }
        return chain
    }

    /// The single parent of a node, or nil at the root (or when the parent
    /// cannot be resolved).
    static func parent(of node: IAMNode, on db: any Database) async throws -> IAMNode? {
        try await step(from: node, on: db).parent
    }

    /// One step up the tree, plus whatever the loaded row says about the node
    /// itself. Callers walking past the first node ignore the facts; the
    /// authorization path keeps the first step's, which is why the leaf row is
    /// never read twice.
    private static func step(
        from node: IAMNode, on db: any Database
    ) async throws -> (parent: IAMNode?, leaf: IAMLeafFacts) {
        switch node.type {
        case .organization:
            return (nil, IAMLeafFacts())

        case .user:
            // A user record is parentless by construction: users belong to
            // organizations as a *set* (`memberOfOrgs` on the principal
            // entity), and the tree's one-parent invariant cannot express
            // that. Access to a user record comes from the two tier-1
            // policies instead of from anything inherited.
            return (nil, IAMLeafFacts())

        case .organizationalUnit:
            guard let ou = try await OrganizationalUnit.find(node.id, on: db) else { return (nil, IAMLeafFacts()) }
            if let parentOUID = ou.$parentOU.id {
                return (IAMNode(type: .organizationalUnit, id: parentOUID), IAMLeafFacts())
            }
            return (IAMNode(type: .organization, id: ou.$organization.id), IAMLeafFacts())

        case .project:
            guard let project = try await Project.find(node.id, on: db) else { return (nil, IAMLeafFacts()) }
            if let ouID = project.$organizationalUnit.id {
                return (IAMNode(type: .organizationalUnit, id: ouID), IAMLeafFacts())
            }
            if let orgID = project.$organization.id {
                return (IAMNode(type: .organization, id: orgID), IAMLeafFacts())
            }
            return (nil, IAMLeafFacts())

        case .virtualMachine:
            guard let vm = try await VM.find(node.id, on: db) else { return (nil, IAMLeafFacts()) }
            return (IAMNode(type: .project, id: vm.$project.id), IAMLeafFacts(environment: vm.environment))

        case .sandbox:
            guard let sandbox = try await Sandbox.find(node.id, on: db) else { return (nil, IAMLeafFacts()) }
            return (
                IAMNode(type: .project, id: sandbox.$project.id), IAMLeafFacts(environment: sandbox.environment)
            )

        case .image:
            guard let image = try await Image.find(node.id, on: db) else { return (nil, IAMLeafFacts()) }
            return (IAMNode(type: .project, id: image.$project.id), IAMLeafFacts())

        case .volume:
            guard let volume = try await Volume.find(node.id, on: db) else { return (nil, IAMLeafFacts()) }
            return (IAMNode(type: .project, id: volume.$project.id), IAMLeafFacts())

        case .volumeSnapshot:
            guard let snapshot = try await VolumeSnapshot.find(node.id, on: db) else { return (nil, IAMLeafFacts()) }
            // A snapshot references its volume by attribute, not as a parent
            // (docs/architecture/iam.md) — its container is the project.
            return (IAMNode(type: .project, id: snapshot.$project.id), IAMLeafFacts())

        case .sandboxSnapshot:
            guard let snapshot = try await SandboxSnapshot.find(node.id, on: db) else { return (nil, IAMLeafFacts()) }
            return (
                IAMNode(type: .project, id: snapshot.$project.id), IAMLeafFacts(environment: snapshot.environment)
            )

        case .network:
            guard let network = try await LogicalNetwork.find(node.id, on: db) else { return (nil, IAMLeafFacts()) }
            let facts = IAMLeafFacts(
                networkHasProject: network.$project.id != nil, networkHasSite: network.$site.id != nil)
            if let projectID = network.$project.id {
                return (IAMNode(type: .project, id: projectID), facts)
            }
            // A site-scoped network has no project; it inherits from whichever
            // org or folder owns the site's capacity.
            guard let siteID = network.$site.id else { return (nil, facts) }
            return (try await parent(of: IAMNode(type: .site, id: siteID), on: db), facts)

        case .floatingIP:
            guard let floatingIP = try await FloatingIP.find(node.id, on: db) else { return (nil, IAMLeafFacts()) }
            return (IAMNode(type: .project, id: floatingIP.$project.id), IAMLeafFacts())

        case .securityGroup:
            guard let group = try await SecurityGroup.find(node.id, on: db) else { return (nil, IAMLeafFacts()) }
            return (IAMNode(type: .project, id: group.$project.id), IAMLeafFacts())

        case .site:
            guard let site = try await Site.find(node.id, on: db) else { return (nil, IAMLeafFacts()) }
            return (scopeNode(ouID: site.$organizationalUnit.id, orgID: site.$organization.id), IAMLeafFacts())

        case .agent:
            guard let agent = try await Agent.find(node.id, on: db) else { return (nil, IAMLeafFacts()) }
            return (scopeNode(ouID: agent.$organizationalUnit.id, orgID: agent.$organization.id), IAMLeafFacts())

        case .serviceAccount:
            guard let account = try await ServiceAccount.find(node.id, on: db) else { return (nil, IAMLeafFacts()) }
            return (IAMNode(type: .project, id: account.$project.id), IAMLeafFacts())
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
