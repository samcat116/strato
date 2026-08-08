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

    /// The fully-migrated schema is the *fresh database* half of STR-152: the
    /// migrations that built `resource_operations` are deleted rather than
    /// reverted, so the table is simply never created.
    @Test("The retired operations table is absent from the migrated schema")
    func resourceOperationsIsAbsent() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? SQLDatabase)
            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT id FROM resource_operations").all()
            }
        }
    }

    /// And the *existing database* half. A deployment upgrading into this build
    /// still has the table, its rows, its indexes and the `CHECK` constraints
    /// `EnforcePersistedEnumValues` installed on it — none of which the deleted
    /// migrations are around to take down. `DropResourceOperations` is the only
    /// thing that removes them, so it is worth asserting against a table shaped
    /// like the one it will actually meet rather than against nothing.
    @Test("The drop migration removes a pre-upgrade operations table and its dependents")
    func dropMigrationRemovesPreUpgradeTable() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? SQLDatabase)

            try await sql.raw(
                """
                CREATE TABLE resource_operations (
                    id uuid PRIMARY KEY,
                    resource_kind text NOT NULL DEFAULT 'virtual_machine',
                    resource_id uuid NOT NULL,
                    user_id uuid NOT NULL,
                    kind text NOT NULL,
                    status text NOT NULL,
                    error text,
                    created_at timestamptz,
                    completed_at timestamptz,
                    organization_id uuid,
                    project_id uuid,
                    resource_name text,
                    CONSTRAINT ck_resource_operations_status_enum
                        CHECK (status IN ('pending', 'succeeded', 'failed'))
                )
                """
            ).run()
            try await sql.raw(
                "CREATE UNIQUE INDEX idx_resource_operations_pending_resource "
                    + "ON resource_operations (resource_kind, resource_id) WHERE status = 'pending'"
            ).run()
            // A row the previous build left `pending` — the case the sweep and
            // the verdict path survived nine stages to take terminal.
            try await sql.raw(
                """
                INSERT INTO resource_operations (id, resource_id, user_id, kind, status, created_at)
                VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'boot', 'pending', now())
                """
            ).run()

            try await DropResourceOperations().prepare(on: app.db)

            await #expect(throws: (any Error).self) {
                _ = try await sql.raw("SELECT id FROM resource_operations").all()
            }
            let indexes = try await sql.raw(
                "SELECT indexname FROM pg_indexes WHERE schemaname = current_schema() "
                    + "AND tablename = 'resource_operations'"
            ).all()
            #expect(indexes.isEmpty)

            // Idempotent: a replica that runs it twice, or a fresh database
            // that never had the table, must not fail.
            try await DropResourceOperations().prepare(on: app.db)
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
}
