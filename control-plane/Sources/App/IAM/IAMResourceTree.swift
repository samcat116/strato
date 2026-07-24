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
        let resolved = try await resolve([node], cache: cache, on: db)
        // The batch is total over its inputs; the fallback is unreachable and
        // exists only so the single-node form need not force-unwrap.
        return resolved[node] ?? Resolution(chain: [node], leaf: IAMLeafFacts())
    }

    /// Resolve many nodes in one walk (#687).
    ///
    /// This is the only walk: the single-node form above is a batch of one, so
    /// there is no second chain-building implementation to drift from this one.
    /// Every level of the tree is one query *per node type in the frontier*,
    /// for the whole batch at once — a hundred VMs in a list cost the same
    /// three or four queries one VM does, instead of three or four each.
    static func resolve(
        _ nodes: [IAMNode], cache: IAMRequestCache? = nil, on db: any Database
    ) async throws -> [IAMNode: Resolution] {
        var resolved: [IAMNode: Resolution] = [:]
        var pending: [IAMNode] = []
        for node in Set(nodes) {
            if let cached = cache?.chain(of: node) {
                resolved[node] = cached
            } else {
                pending.append(node)
            }
        }
        guard !pending.isEmpty else { return resolved }

        for (node, resolution) in try await walk(from: pending, cache: cache, on: db) {
            cache?.store(chain: resolution, of: node)
            resolved[node] = resolution
            // Cache each container above the leaf too (#710), so a later check
            // on a sibling leaf in the same project reuses the shared
            // project→org chain instead of re-walking it. Every node above a
            // leaf is a container (project/folder/org), and containers carry no
            // leaf facts (environment and network attributes live only on
            // leaves), so each one's resolution is exactly its suffix with
            // empty facts.
            //
            // Within one batch this is redundant — the lockstep walk already
            // resolves a shared container once for every path through it — but
            // it is what carries the saving *across* calls: the middleware's
            // single check, then the handler's batch, then a second batch for a
            // different action.
            if let cache {
                let chain = resolution.chain
                for index in chain.indices.dropFirst() where cache.chain(of: chain[index]) == nil {
                    cache.store(
                        chain: Resolution(chain: Array(chain[index...]), leaf: IAMLeafFacts()), of: chain[index])
                }
            }
        }
        return resolved
    }

    /// One node's walk in progress: the chain so far, the nodes it has already
    /// visited (the cycle guard), the facts harvested from its own row, and the
    /// node whose parent is wanted next — nil once the walk has terminated.
    private struct Path {
        var chain: [IAMNode]
        var seen: Set<IAMNode>
        var leaf: IAMLeafFacts
        var cursor: IAMNode?
    }

    /// One step up the tree: the parent, and whatever the loaded row says about
    /// the node itself. Callers walking past the first node ignore the facts;
    /// the authorization path keeps the first step's, which is why the leaf row
    /// is never read twice.
    private struct Step {
        let parent: IAMNode?
        let leaf: IAMLeafFacts
    }

    /// Walk every path upward in lockstep, one batched query per (level, type).
    private static func walk(
        from starts: [IAMNode], cache: IAMRequestCache?, on db: any Database
    ) async throws -> [IAMNode: Resolution] {
        var paths: [IAMNode: Path] = [:]
        for start in starts {
            paths[start] = Path(chain: [start], seen: [start], leaf: IAMLeafFacts(), cursor: start)
        }
        // Folder rows are memoized across levels because their materialized
        // paths let one query pull an entire remaining chain — see `step`.
        var folders = FolderRows()

        for _ in 0..<maxDepth {
            var frontier: [IAMNodeType: Set<UUID>] = [:]
            for path in paths.values {
                guard let cursor = path.cursor else { continue }
                frontier[cursor.type, default: []].insert(cursor.id)
            }
            if frontier.isEmpty { break }

            var steps: [IAMNode: Step] = [:]
            for type in frontier.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                let level = try await step(ids: frontier[type]!, type: type, folders: &folders, on: db)
                for (id, step) in level { steps[IAMNode(type: type, id: id)] = step }
            }

            for (start, var path) in paths {
                guard let cursor = path.cursor else { continue }
                defer { paths[start] = path }
                path.cursor = nil

                guard let step = steps[cursor] else {
                    // No row behind the node. A dangling *folder* leaves the
                    // chain entirely — folder chains have always been assembled
                    // from rows that exist, so a binding on a deleted folder
                    // must not start applying — while every other type stays in
                    // the chain and simply ends it, which is what the walk has
                    // always done for a dangling project or site.
                    if cursor.type == .organizationalUnit { path.chain.removeLast() }
                    continue
                }
                if cursor == start { path.leaf = step.leaf }
                guard let next = step.parent, path.chain.count < maxDepth else { continue }
                // An earlier call already resolved the chain above this parent
                // (#710) — splice its cycle-free suffix and stop, skipping the
                // rest of the walk. Within a batch the lockstep walk already
                // shares a container between siblings, so what this buys is
                // reuse across calls: the middleware's single check leaves the
                // project→org chain cached for the handler's batch. A splice can
                // leave the chain slightly past maxDepth, but only in a corrupt
                // tree already deeper than the cap the real schema cannot
                // produce — the cap is a runaway guard, not a correctness bound.
                if let cachedParent = cache?.chain(of: next) {
                    for ancestor in cachedParent.chain where path.seen.insert(ancestor).inserted {
                        path.chain.append(ancestor)
                    }
                    continue
                }
                guard path.seen.insert(next).inserted else { continue }
                path.chain.append(next)
                path.cursor = next
            }
        }

        return paths.mapValues { Resolution(chain: $0.chain, leaf: $0.leaf) }
    }

    /// Folder rows already loaded by this walk.
    ///
    /// The parent pointers stay authoritative: the materialized `path`
    /// (`/orgId/ouId/…/selfId`) is used only as a *prefetch hint*, pulling the
    /// rows the walk is about to need in one query instead of one per level. A
    /// stale or unparsable path therefore costs a query, never a wrong chain —
    /// which matters because the chain decides which bindings and which
    /// guardrails apply.
    private struct FolderRows {
        var rows: [UUID: OrganizationalUnit] = [:]
        /// Ids already queried for, so an id the hint named but the table does
        /// not have is not re-queried at every level.
        var attempted: Set<UUID> = []
    }

    /// One step up the tree for a whole level of same-typed nodes.
    ///
    /// A node whose row is missing is simply absent from the result; callers
    /// read that as "the chain ends here".
    private static func step(
        ids: Set<UUID>, type: IAMNodeType, folders: inout FolderRows, on db: any Database
    ) async throws -> [UUID: Step] {
        let idList = Array(ids)

        /// The shape almost every resource shares: contained by its project.
        func projectParents<M: Model>(
            _ rows: [M], id: (M) -> UUID?, projectID: (M) -> UUID, environment: (M) -> String? = { _ in nil }
        ) -> [UUID: Step] {
            var steps: [UUID: Step] = [:]
            for row in rows {
                guard let rowID = id(row) else { continue }
                steps[rowID] = Step(
                    parent: IAMNode(type: .project, id: projectID(row)),
                    leaf: IAMLeafFacts(environment: environment(row)))
            }
            return steps
        }

        switch type {
        case .organization:
            return Dictionary(uniqueKeysWithValues: idList.map { ($0, Step(parent: nil, leaf: IAMLeafFacts())) })

        case .user:
            // A user record is parentless by construction: users belong to
            // organizations as a *set* (`memberOfOrgs` on the principal
            // entity), and the tree's one-parent invariant cannot express
            // that. Access to a user record comes from the two tier-1
            // policies instead of from anything inherited.
            return Dictionary(uniqueKeysWithValues: idList.map { ($0, Step(parent: nil, leaf: IAMLeafFacts())) })

        case .organizationalUnit:
            let unknown = ids.subtracting(folders.attempted)
            if !unknown.isEmpty {
                folders.attempted.formUnion(unknown)
                for row in try await OrganizationalUnit.query(on: db).filter(\.$id ~~ Array(unknown)).all() {
                    if let id = row.id { folders.rows[id] = row }
                }
            }
            // Pull the rest of every folder chain in this level in one query,
            // hinted by the materialized paths, so depth costs a query rather
            // than a query per level.
            let hinted = Set(ids.compactMap { folders.rows[$0] }.flatMap { $0.ancestorAndSelfOUIDs() })
                .subtracting(folders.attempted)
            if !hinted.isEmpty {
                folders.attempted.formUnion(hinted)
                for row in try await OrganizationalUnit.query(on: db).filter(\.$id ~~ Array(hinted)).all() {
                    if let id = row.id { folders.rows[id] = row }
                }
            }
            var steps: [UUID: Step] = [:]
            for id in ids {
                guard let ou = folders.rows[id] else { continue }
                if let parentOUID = ou.$parentOU.id {
                    steps[id] = Step(
                        parent: IAMNode(type: .organizationalUnit, id: parentOUID), leaf: IAMLeafFacts())
                } else {
                    steps[id] = Step(
                        parent: IAMNode(type: .organization, id: ou.$organization.id), leaf: IAMLeafFacts())
                }
            }
            return steps

        case .project:
            var steps: [UUID: Step] = [:]
            for project in try await Project.query(on: db).filter(\.$id ~~ idList).all() {
                guard let id = project.id else { continue }
                if let ouID = project.$organizationalUnit.id {
                    steps[id] = Step(
                        parent: IAMNode(type: .organizationalUnit, id: ouID), leaf: IAMLeafFacts())
                } else if let orgID = project.$organization.id {
                    steps[id] = Step(parent: IAMNode(type: .organization, id: orgID), leaf: IAMLeafFacts())
                } else {
                    steps[id] = Step(parent: nil, leaf: IAMLeafFacts())
                }
            }
            return steps

        case .virtualMachine:
            return projectParents(
                try await VM.query(on: db).filter(\.$id ~~ idList).all(),
                id: \.id, projectID: { $0.$project.id }, environment: { $0.environment })

        case .sandbox:
            return projectParents(
                try await Sandbox.query(on: db).filter(\.$id ~~ idList).all(),
                id: \.id, projectID: { $0.$project.id }, environment: { $0.environment })

        case .image:
            return projectParents(
                try await Image.query(on: db).filter(\.$id ~~ idList).all(),
                id: \.id, projectID: { $0.$project.id })

        case .volume:
            return projectParents(
                try await Volume.query(on: db).filter(\.$id ~~ idList).all(),
                id: \.id, projectID: { $0.$project.id })

        case .volumeSnapshot:
            // A snapshot references its volume by attribute, not as a parent
            // (docs/architecture/iam.md) — its container is the project.
            return projectParents(
                try await VolumeSnapshot.query(on: db).filter(\.$id ~~ idList).all(),
                id: \.id, projectID: { $0.$project.id })

        case .sandboxSnapshot:
            return projectParents(
                try await SandboxSnapshot.query(on: db).filter(\.$id ~~ idList).all(),
                id: \.id, projectID: { $0.$project.id }, environment: { $0.environment })

        case .floatingIP:
            return projectParents(
                try await FloatingIP.query(on: db).filter(\.$id ~~ idList).all(),
                id: \.id, projectID: { $0.$project.id })

        case .securityGroup:
            return projectParents(
                try await SecurityGroup.query(on: db).filter(\.$id ~~ idList).all(),
                id: \.id, projectID: { $0.$project.id })

        case .serviceAccount:
            return projectParents(
                try await ServiceAccount.query(on: db).filter(\.$id ~~ idList).all(),
                id: \.id, projectID: { $0.$project.id })

        case .network:
            var steps: [UUID: Step] = [:]
            var siteScoped: [UUID: UUID] = [:]
            for network in try await LogicalNetwork.query(on: db).filter(\.$id ~~ idList).all() {
                guard let id = network.id else { continue }
                let facts = IAMLeafFacts(
                    networkHasProject: network.$project.id != nil, networkHasSite: network.$site.id != nil)
                if let projectID = network.$project.id {
                    steps[id] = Step(parent: IAMNode(type: .project, id: projectID), leaf: facts)
                    continue
                }
                // A site-scoped network has no project; it inherits from
                // whichever org or folder owns the site's capacity. The site
                // itself is not part of the chain, so it is resolved here
                // rather than walked through.
                steps[id] = Step(parent: nil, leaf: facts)
                if let siteID = network.$site.id { siteScoped[id] = siteID }
            }
            if !siteScoped.isEmpty {
                var scopes: [UUID: IAMNode] = [:]
                for site in try await Site.query(on: db).filter(\.$id ~~ Array(Set(siteScoped.values))).all() {
                    guard let id = site.id,
                        let scope = scopeNode(ouID: site.$organizationalUnit.id, orgID: site.$organization.id)
                    else { continue }
                    scopes[id] = scope
                }
                for (networkID, siteID) in siteScoped {
                    guard let leaf = steps[networkID]?.leaf else { continue }
                    steps[networkID] = Step(parent: scopes[siteID], leaf: leaf)
                }
            }
            return steps

        case .site:
            var steps: [UUID: Step] = [:]
            for site in try await Site.query(on: db).filter(\.$id ~~ idList).all() {
                guard let id = site.id else { continue }
                steps[id] = Step(
                    parent: scopeNode(ouID: site.$organizationalUnit.id, orgID: site.$organization.id),
                    leaf: IAMLeafFacts())
            }
            return steps

        case .agent:
            var steps: [UUID: Step] = [:]
            for agent in try await Agent.query(on: db).filter(\.$id ~~ idList).all() {
                guard let id = agent.id else { continue }
                steps[id] = Step(
                    parent: scopeNode(ouID: agent.$organizationalUnit.id, orgID: agent.$organization.id),
                    leaf: IAMLeafFacts())
            }
            return steps
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
