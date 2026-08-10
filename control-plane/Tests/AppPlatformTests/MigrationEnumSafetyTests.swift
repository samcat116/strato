import Fluent
import Foundation
import SQLKit
import Testing

import AppTestSupport
@testable import App

@Suite("Migration enum safety", .serialized)
struct MigrationEnumSafetyTests {
    @Test("Boot-volume cutover backfills a canonical managed identity before dropping VM paths")
    func bootVolumeCutoverBackfillsMissingVolume() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let cutover = MakeVMBootVolumesAuthoritative()
            try await cutover.revert(on: app.db)

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(isSystemAdmin: true)
            let userID = try user.requireID()
            let organization = try await builder.createOrganization()
            let project = try await builder.createProject(
                name: "boot-cutover", description: "", organization: organization)
            let vm = try await builder.createVM(name: "boot-cutover", project: project)
            try await RoleBindingService.grant(
                principalType: .user, principalID: userID, role: .admin,
                nodeType: .virtualMachine, nodeID: try vm.requireID(),
                createdBy: user.id, on: app.db)
            let legacyPath = "/var/lib/strato/vms/\(try vm.requireID())/disk.qcow2"
            try await sql.raw(
                "UPDATE vms SET disk_path = \(bind: legacyPath), readonly_disk = true "
                    + "WHERE id = \(bind: vm.id!)"
            ).run()

            try await cutover.prepare(on: app.db)

            struct BootRow: Decodable {
                let id: UUID
                let device_name: String
                let boot_order: Int
                let readonly: Bool
                let status: String
                let observed_generation: Int64
            }
            let rows = try await sql.raw(
                """
                SELECT id, device_name, boot_order, readonly,
                       status::text AS status, observed_generation
                FROM volumes
                WHERE vm_id = \(bind: vm.id!) AND type::text = 'boot'
                """
            ).all(decoding: BootRow.self)
            let boot = try #require(rows.first)
            #expect(rows.count == 1)
            #expect(boot.device_name == "disk0")
            #expect(boot.boot_order == 0)
            #expect(!boot.readonly)
            #expect(boot.status == VolumeStatus.creating.rawValue)
            #expect(boot.observed_generation == 0)

            let replicas = try await VolumeReplica.query(on: app.db)
                .filter(\.$volume.$id == boot.id)
                .count()
            #expect(replicas == 0)
            let copiedGrant = try await RoleBinding.query(on: app.db)
                .filter(\.$principalID == userID)
                .filter(\.$nodeType == IAMNodeType.volume.rawValue)
                .filter(\.$nodeID == boot.id)
                .count()
            #expect(copiedGrant == 1)

            struct ColumnCount: Decodable { let count: Int }
            let removed = try #require(
                try await sql.raw(
                    """
                    SELECT COUNT(*)::int AS count
                    FROM information_schema.columns
                    WHERE table_name = 'vms'
                      AND column_name IN ('disk_path', 'readonly_disk')
                    """
                ).first(decoding: ColumnCount.self))
            #expect(removed.count == 0)
        }
    }

    @Test("VM disk backfill does not load malformed VM enum values")
    func vmDiskBackfillUsesSchemaSnapshot() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            // The production schema has already removed these compatibility
            // columns. Restore the immediately preceding schema so this test
            // can continue exercising the frozen historical migration.
            try await MakeVMBootVolumesAuthoritative().revert(on: app.db)
            let builder = TestDataBuilder(db: app.db)
            _ = try await builder.createUser(isSystemAdmin: true)
            let organization = try await builder.createOrganization()
            let project = try await builder.createProject(
                name: "vm-enum-safety", description: "", organization: organization)
            let vm = try await builder.createVM(name: "vm-enum-safety", project: project)
            try await sql.raw(
                "UPDATE vms SET disk_path = '/var/lib/strato/vms/enum-safety.qcow2' "
                    + "WHERE id = \(bind: vm.id!)"
            ).run()

            try await removeConstraint(table: "vms", column: "status", on: app.db)
            try await sql.raw(
                "UPDATE vms SET status = '''Created''' WHERE id = \(bind: vm.id!)"
            ).run()

            // A live VM query would decode status before the repair migration
            // runs and terminate the process. The historical-schema snapshot
            // only selects the fields this backfill actually needs.
            try await MigrateVMDisksToVolumes().prepare(on: app.db)

            let row = try #require(
                try await sql.raw(
                    "SELECT storage_path FROM volumes WHERE vm_id = \(bind: vm.id!)"
                ).first()
            )
            #expect(
                try row.decode(column: "storage_path", as: String.self)
                    == "/var/lib/strato/vms/enum-safety.qcow2"
            )
        }
    }

    private func removeConstraint(table: String, column: String, on database: Database) async throws {
        let constraint = try #require(
            EnforcePersistedEnumValues.constraints.first {
                $0.table == table && $0.column == column
            })
        try await EnforcePersistedEnumValues.revert(constraint, on: database)
    }
}
