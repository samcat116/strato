import Fluent
import Vapor

/// Who may read and write IAM policy on a node.
///
/// Both are administrative acts: reading tells you who holds access to
/// something, and writing changes it. The rule is the same for each — system
/// admin, or admin over the node itself or any container above it — so it
/// lives in one place rather than being restated per controller.
///
/// Gated through SpiceDB because SpiceDB is what enforces today. At cutover
/// (#482) these become `iam:readPolicy` / `iam:setPolicy` through the
/// evaluator and the permission-name indirection below goes away.
enum IAMPolicyGate {

    /// The SpiceDB permission standing for "administrative control of this
    /// node" — the grantee set allowed to read or set policy here.
    ///
    /// Containers have an explicit `manage_*`. Individual resources have no
    /// `manage` in `schema.zed`; their `delete` is the permission whose
    /// grantees are exactly the resource owner plus project admins, which is
    /// the set we want. Gating a *read* on `delete` reads oddly, so: this is a
    /// grantee-set equivalence, not a claim that the caller may delete
    /// anything.
    ///
    /// Every node type maps to something — a type with no entry here would
    /// silently fall through to its containers and deny its own owners.
    static func adminPermission(for nodeType: IAMNodeType) -> String {
        switch nodeType {
        case .organization: return "manage_organization"
        case .organizationalUnit: return "manage_ou"
        case .project: return "manage_project"
        case .site, .agent: return "manage"
        case .virtualMachine, .sandbox, .image, .volume, .network,
            .volumeSnapshot, .sandboxSnapshot:
            return "delete"
        }
    }

    /// Require admin over `node` or a container above it.
    ///
    /// The node itself is checked too, not just its containers: resource-level
    /// grants exist from day one, so a VM's owner can audit their own VM
    /// without holding project admin.
    ///
    /// `deniedReason` names the act being gated, because "forbidden" alone
    /// leaves the caller guessing which of their permissions fell short.
    static func requireAdmin(
        on node: IAMNode, caller: User, deniedReason: String, req: Request
    ) async throws {
        if caller.isSystemAdmin { return }
        guard let callerID = caller.id?.uuidString else { throw Abort(.unauthorized) }

        let chain = try await IAMResourceTree.ancestors(of: node, on: req.db)
        for ancestor in chain {
            let allowed = try await req.spicedb.checkPermission(
                subject: callerID,
                permission: adminPermission(for: ancestor.type),
                resource: ancestor.type.rawValue,
                resourceId: ancestor.id.uuidString
            )
            if allowed { return }
        }
        throw Abort(.forbidden, reason: deniedReason)
    }

    /// Parse a `(resourceType, resourceId)` pair into a tree node. An unknown
    /// type is a `400`, not a `403` — naming a type that does not exist is a
    /// malformed request, not a denied one.
    static func node(resourceType: String, resourceId: String) throws -> IAMNode {
        guard let type = IAMNodeType(rawValue: resourceType) else {
            throw Abort(.badRequest, reason: "Unknown resource type '\(resourceType)'")
        }
        guard let id = UUID(uuidString: resourceId) else {
            throw Abort(.badRequest, reason: "Resource id must be a UUID")
        }
        return IAMNode(type: type, id: id)
    }
}
