import Fluent
import SQLKit
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// STR-112: deleting a resource has to take its role bindings with it, because
/// `role_bindings` has no foreign key to the node it names.
///
/// The delete paths themselves are covered where they live (`VMOperationTests`,
/// `SandboxTests`, `DesiredStateReconciliationTests`, `ImageControllerTests`).
/// What these tests guard is the part no call site can assert: that
/// `ResourceBindingCleanup` still knows about every child the database quietly
/// deletes along with a VM or a sandbox.
@Suite("Resource Binding Cleanup", .serialized)
struct ResourceBindingCleanupTests {

    /// Delete actions Postgres records in `pg_constraint.confdeltype`. Only
    /// `c` — CASCADE — removes the child row, and so orphans its bindings.
    private static let cascadeDeleteAction = "c"

    @Test("Every cascading child of a VM or sandbox is a node type the cleanup revokes")
    func cascadingChildrenAreCovered() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)

            // The set the helper declares is inert on its own; hold it against
            // the schema the database actually enforces. A new child table
            // added with ON DELETE CASCADE would otherwise compile and pass
            // while leaking its bindings on every parent delete — the exact
            // failure STR-112 was.
            for (parent, declaredChildren) in ResourceBindingCleanup.cascadingChildren {
                let rows = try await sql.raw(
                    """
                    SELECT child.relname AS child_table
                    FROM pg_constraint AS fk
                    JOIN pg_class AS child ON child.oid = fk.conrelid
                    JOIN pg_class AS parent ON parent.oid = fk.confrelid
                    WHERE fk.contype = 'f'
                      AND fk.confdeltype = \(bind: Self.cascadeDeleteAction)
                      AND parent.relname = \(bind: parent.table)
                    """
                ).all()
                let cascadingTables = Set(
                    try rows.map { try $0.decode(column: "child_table", as: String.self) })

                // Only cascading children that are themselves bindable matter:
                // a NIC or an interface-address row carries no bindings, so its
                // removal orphans nothing.
                let bindableChildren = IAMNodeType.allCases.filter { cascadingTables.contains($0.table) }
                for child in bindableChildren {
                    #expect(
                        declaredChildren.contains(child),
                        """
                        \(child.rawValue) rows cascade away with \(parent.rawValue) rows, \
                        so their bindings orphan on every \(parent.rawValue) delete. \
                        Add it to ResourceBindingCleanup.cascadingChildren and revoke it.
                        """)
                }
            }
        }
    }

    @Test("Revoking for a deleted VM clears the VM's bindings and its checkpoints'")
    func revokesVMAndCheckpoints() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "cleanup", email: "cleanup@example.com")
            let org = try await builder.createOrganization(name: "Cleanup Org")
            let project = try await builder.createProject(
                name: "Cleanup Project", description: "binding cleanup", organization: org)
            let vm = try await builder.createVM(name: "cleanup-vm", project: project)
            let vmID = try vm.requireID()

            let snapshot = VMSnapshot(
                name: "checkpoint", vmID: vmID, projectID: project.id!,
                environment: vm.environment, agentId: nil, createdByID: user.id!)
            try await snapshot.save(on: app.db)
            let snapshotID = try snapshot.requireID()

            // A sibling VM's binding stands in for every binding the sweep must
            // not touch.
            let bystander = try await builder.createVM(name: "bystander-vm", project: project)
            let bystanderID = try bystander.requireID()

            for (nodeType, nodeID) in [
                (IAMNodeType.virtualMachine, vmID),
                (.vmSnapshot, snapshotID),
                (.virtualMachine, bystanderID),
            ] {
                try await RoleBindingService.grant(
                    principalType: .user, principalID: user.id!, role: .admin,
                    nodeType: nodeType, nodeID: nodeID, createdBy: user.id!, on: app.db)
            }

            try await ResourceBindingCleanup.revokeBindings(forDeletedVM: vmID, on: app.db)

            func count(_ nodeType: IAMNodeType, _ nodeID: UUID) async throws -> Int {
                try await RoleBinding.query(on: app.db)
                    .filter(\.$nodeType == nodeType.rawValue)
                    .filter(\.$nodeID == nodeID)
                    .count()
            }
            let vmBindings = try await count(.virtualMachine, vmID)
            let snapshotBindings = try await count(.vmSnapshot, snapshotID)
            let bystanderBindings = try await count(.virtualMachine, bystanderID)
            #expect(vmBindings == 0)
            #expect(snapshotBindings == 0)
            #expect(bystanderBindings == 1)
        }
    }
}
