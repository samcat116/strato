import Fluent
import Foundation

/// Drops the role bindings of a resource whose row is being removed.
///
/// `role_bindings` deliberately carries no foreign key to the node it protects
/// (an operation row has to be able to outlive its resource, and bindings sit
/// in the same "no FK to the resource" boat), so nothing reclaims a binding
/// whose node is gone: every delete path owns that cleanup itself, and a path
/// that forgets leaks the row permanently (STR-112).
///
/// VMs and sandboxes get a helper rather than a bare
/// `RoleBindingService.revokeAll(nodeType:nodeID:)` at the call site for two
/// reasons. Each has two removal sites — the agent-confirmed one in
/// `ObservedStateApplier` and the direct one in its controller, for an unplaced
/// resource or an offline agent — and each takes child nodes with it:
/// `vm_snapshots` / `sandbox_snapshots` cascade on their parent's foreign key,
/// so their bindings are orphaned by the same delete that orphans the parent's.
enum ResourceBindingCleanup {
    /// The node types whose rows cascade away with a parent's, keyed by the
    /// parent. Declared rather than inferred so the tests can hold it against
    /// the schema: `ResourceBindingCleanupTests` walks the real `ON DELETE
    /// CASCADE` foreign keys into each parent table and fails if one arrives
    /// that names an IAM node type absent from here. A new cascading child that
    /// is a bindable node would otherwise compile, pass, and silently leak —
    /// the exact failure this type exists to fix.
    static let cascadingChildren: [IAMNodeType: [IAMNodeType]] = [
        .virtualMachine: [.vmSnapshot],
        .sandbox: [.sandboxSnapshot],
    ]

    /// Revoke every binding on a VM node and on the checkpoints that cascade
    /// away with it. Call inside the transaction that removes the VM row, so
    /// bindings and rows can never diverge — and *before* the delete, which
    /// takes the `vm_snapshots` rows this reads with it.
    static func revokeBindings(forDeletedVM vmID: UUID, on db: any Database) async throws {
        let snapshotIDs = try await VMSnapshot.query(on: db)
            .filter(\.$vm.$id == vmID)
            .all(\.$id)
        try await RoleBindingService.revokeAll(nodeType: .vmSnapshot, nodeIDs: snapshotIDs, on: db)
        try await RoleBindingService.revokeAll(nodeType: .virtualMachine, nodeID: vmID, on: db)
    }

    /// Sandbox counterpart: the sandbox node plus the snapshots that cascade
    /// away with it (issue #428). Same read-before-delete ordering requirement.
    static func revokeBindings(forDeletedSandbox sandboxID: UUID, on db: any Database) async throws {
        let snapshotIDs = try await SandboxSnapshot.query(on: db)
            .filter(\.$sandbox.$id == sandboxID)
            .all(\.$id)
        try await RoleBindingService.revokeAll(nodeType: .sandboxSnapshot, nodeIDs: snapshotIDs, on: db)
        try await RoleBindingService.revokeAll(nodeType: .sandbox, nodeID: sandboxID, on: db)
    }
}
