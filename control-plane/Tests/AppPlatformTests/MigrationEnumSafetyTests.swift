import Fluent
import SQLKit
import Testing

import AppTestSupport
@testable import App

@Suite("Migration enum safety", .serialized)
struct MigrationEnumSafetyTests {
    @Test("VM disk backfill does not load malformed VM enum values")
    func vmDiskBackfillUsesSchemaSnapshot() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let builder = TestDataBuilder(db: app.db)
            _ = try await builder.createUser(isSystemAdmin: true)
            let organization = try await builder.createOrganization()
            let project = try await builder.createProject(
                name: "vm-enum-safety", description: "", organization: organization)
            let vm = try await builder.createVM(name: "vm-enum-safety", project: project)
            vm.diskPath = "/var/lib/strato/vms/enum-safety.qcow2"
            try await vm.save(on: app.db)

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
