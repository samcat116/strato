import SQLKit
import Testing
import Vapor
import Fluent
import VaporTesting
import AppTestSupport
@testable import App

/// Validates that the full migration set applies *and* reverses cleanly against
/// the configured database engine.
///
/// This is the guard for issue #195: it exercises every migration's `prepare`
/// and `revert` — including raw Postgres-specific SQL — against the real
/// engine production uses.
@Suite("Migration Round Trip", .serialized)
struct MigrationRoundTripTests {

    @Test("All migrations apply, revert, and re-apply cleanly")
    func migrationsRoundTrip() async throws {
        try await withTestApp { app in
            // The app's database is a clone of the template every migration was
            // applied to. Drive a full down → up cycle so a broken `revert` or a
            // non-idempotent `prepare` surfaces here rather than in production.
            try await app.autoRevert()
            try await app.autoMigrate()

            // Sanity check: after re-applying, a core table is queryable.
            let userCount = try await User.query(on: app.db).count()
            #expect(userCount == 0)

            // Second cycle: teardown no longer reverts (per-test databases are
            // simply dropped), so confirm revert is repeatable here.
            try await app.autoRevert()
            try await app.autoMigrate()
        }
    }

    @Test("Legacy NIC address columns are dropped from the migrated schema")
    func legacyNICAddressColumnsAreDropped() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? SQLDatabase)

            // DropLegacyVMInterfaceAddressColumns removed the single-address
            // columns; selecting them must fail on the fully-migrated schema.
            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT ip_address FROM vm_network_interfaces").all()
            }
            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT netmask FROM vm_network_interfaces").all()
            }
            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT gateway FROM vm_network_interfaces").all()
            }

            // Their replacement is queryable.
            let addressRows = try await sql.raw("SELECT address FROM vm_interface_addresses").all()
            #expect(addressRows.isEmpty)
        }
    }

    @Test("Every hot-path index is present on the migrated schema")
    func hotPathIndexesArePresent() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? SQLDatabase)

            // The migration's raw SQL only fails loudly if it is malformed, so
            // read the indexes back: a typo'd table or an unsupported partial
            // predicate would otherwise land silently as a missing index and a
            // sequential scan in production.
            let rows = try await sql.raw(
                "SELECT indexname FROM pg_indexes WHERE schemaname = current_schema()"
            ).all()
            let present = Set(try rows.map { try $0.decode(column: "indexname", as: String.self) })

            // `idx_vm_network_interfaces_network` is deliberately absent: its
            // column went away with the name→id re-key, and
            // `RekeyInterfacesToLogicalNetworkID` replaced it with the
            // id-keyed indexes below (issue #765).
            let retired: Set<String> = ["idx_vm_network_interfaces_network"]
            let expected =
                (AddHotPathIndexes.indexes + AddFolderPathIndex.indexes)
                .filter { !retired.contains($0.name) } + RekeyInterfacesToLogicalNetworkID.indexes
                // The three snapshot tables' `agent_id` indexes (STR-150): sync
                // assembly and observed-state application both scan by it, once
                // per poll and once per report.
                + AddConvergenceToSnapshots.agentIndexes.map {
                    (name: $0.index, definition: "\($0.table) (agent_id)")
                }
                // The VM-owned registrations' partial unique index (STR-55):
                // one identity per VM, and the lookup the sync assembly makes
                // once per poll.
                + AddVMToWorkloadRegistration.indexes
            for index in expected {
                let exists = present.contains(index.name)
                #expect(exists, "missing index \(index.name)")
            }
        }
    }

    @Test("The orphan sweep drops bindings whose node is gone and keeps the rest")
    func orphanedRoleBindingSweep() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "sweeper", email: "sweeper@example.com")
            let org = try await builder.createOrganization(name: "Sweep Org")
            let project = try await builder.createProject(
                name: "Sweep Project", description: "orphan sweep", organization: org)
            let vm = try await builder.createVM(name: "live-vm", project: project)

            func grant(_ nodeType: IAMNodeType, _ nodeID: UUID) async throws {
                try await RoleBindingService.grant(
                    principalType: .user, principalID: user.id!, role: .admin,
                    nodeType: nodeType, nodeID: nodeID, createdBy: user.id!, on: app.db)
            }
            func count(_ nodeType: IAMNodeType, _ nodeID: UUID) async throws -> Int {
                try await RoleBinding.query(on: app.db)
                    .filter(\.$nodeType == nodeType.rawValue)
                    .filter(\.$nodeID == nodeID)
                    .count()
            }

            let liveVMID = try vm.requireID()
            let deletedVMID = UUID()
            let deletedSnapshotID = UUID()
            let deletedVolumeID = UUID()
            try await grant(.virtualMachine, liveVMID)
            try await grant(.virtualMachine, deletedVMID)
            try await grant(.vmSnapshot, deletedSnapshotID)
            // A type the sweep deliberately leaves alone, orphan or not: only
            // the types whose delete paths were leaking are in scope.
            try await grant(.volume, deletedVolumeID)

            try await DeleteOrphanedResourceRoleBindings().prepare(on: app.db)

            let liveVMBindings = try await count(.virtualMachine, liveVMID)
            let orphanedVMBindings = try await count(.virtualMachine, deletedVMID)
            let orphanedSnapshotBindings = try await count(.vmSnapshot, deletedSnapshotID)
            let untouchedVolumeBindings = try await count(.volume, deletedVolumeID)
            #expect(liveVMBindings == 1)
            #expect(orphanedVMBindings == 0)
            #expect(orphanedSnapshotBindings == 0)
            #expect(untouchedVolumeBindings == 1)
        }
    }

    @Test("The instance-identity backfill reaches every VM, twice over, and undoes itself")
    func vmWorkloadRegistrationBackfill() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Backfill Org")
            let orgID = try org.requireID()

            // Both legs of the org walk: a project owned directly by the
            // organization, and one owned by a folder that is. `COALESCE` over
            // the two nullable columns is `Project.getRootOrganizationId` in
            // SQL, and a join that got either leg wrong would leave one of
            // these scoped to nothing.
            let directProject = try await builder.createProject(
                name: "Backfill Direct", description: "d", organization: org)
            let folder = try await builder.createOU(
                name: "Backfill Folder", description: "d", organization: org)
            let folderProject = try await builder.createProject(
                name: "Backfill Folder Project", description: "d", ou: folder)

            // `createVM` writes the row directly, so these VMs are genuinely
            // missing an identity — exactly the state a VM created before
            // STR-55 is in.
            let directVM = try await builder.createVM(name: "backfill-direct", project: directProject)
            let folderVM = try await builder.createVM(name: "backfill-folder", project: folderProject)
            let directVMID = try directVM.requireID()
            let folderVMID = try folderVM.requireID()

            func rows(forVM vmID: UUID) async throws -> [WorkloadRegistration] {
                try await WorkloadRegistration.query(on: app.db).filter(\.$vm.$id == vmID).all()
            }

            #expect(try await rows(forVM: directVMID).isEmpty)

            try await BackfillVMWorkloadRegistrations().prepare(on: app.db)

            for (vmID, name) in [(directVMID, "backfill-direct"), (folderVMID, "backfill-folder")] {
                let found = try await rows(forVM: vmID)
                #expect(found.count == 1, "\(name)")
                let row = try #require(found.first)
                #expect(row.kind == .workload)
                // No stored label, matching `GuestIdentity.register`: the
                // registry hydrates it from the VM.
                #expect(row.displayName == nil)
                // The organization is reached through the project either way.
                #expect(row.$organization.id == orgID, "\(name)")
                #expect(
                    row.spiffeID
                        == GuestIdentity.spiffeID(
                            forVM: vmID, trustDomain: PlatformTrustDomain.current),
                    "\(name)")
            }

            // Idempotent: `migrationsRoundTrip` re-applies the whole set, and a
            // second insert would trip the `spiffe_id` unique index.
            try await BackfillVMWorkloadRegistrations().prepare(on: app.db)
            #expect(try await rows(forVM: directVMID).count == 1)
            #expect(try await rows(forVM: folderVMID).count == 1)

            // Not a no-op: the migration above this one drops `vm_id`, so a
            // surviving row would keep squatting its `spiffe_id` while naming
            // nothing, and the re-applied backfill would skip that VM forever.
            try await BackfillVMWorkloadRegistrations().revert(on: app.db)
            let remaining = try await WorkloadRegistration.query(on: app.db).all()
                .filter { $0.$vm.id != nil }
            #expect(remaining.isEmpty)
        }
    }
}
