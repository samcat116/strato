import Fluent
import Vapor

/// Who may read and write IAM policy on a node.
///
/// Both are administrative acts: reading tells you who holds access to
/// something, and writing changes it. The rule is the same for each — the
/// `iam:readPolicy` / `iam:setPolicy` actions, which only the `admin` role
/// carries — so it lives in one place rather than being restated per
/// controller. Since cutover (#482) it is a single evaluator check: the
/// entity slice carries the node's ancestor chain, so admin anywhere above
/// the node grants it, and system admins are allowed by the
/// `platform-system-admin` policy like everywhere else.
enum IAMPolicyGate {

    /// Require `iam:readPolicy` on `node` — the gate for who-can, can-i about
    /// another principal, and reading guardrails.
    ///
    /// `deniedReason` names the act being gated, because "forbidden" alone
    /// leaves the caller guessing which of their permissions fell short.
    static func requirePolicyRead(on node: IAMNode, deniedReason: String, req: Request) async throws {
        guard try await req.can("iam:readPolicy", on: node) else {
            throw Abort(.forbidden, reason: deniedReason)
        }
    }

    /// Require `iam:setPolicy` on `node` — the gate for writing guardrails
    /// and, as later phases move them here, role bindings.
    static func requirePolicyWrite(on node: IAMNode, deniedReason: String, req: Request) async throws {
        guard try await req.can("iam:setPolicy", on: node) else {
            throw Abort(.forbidden, reason: deniedReason)
        }
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
