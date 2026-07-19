import Fluent
import SQLKit
import Testing

@testable import App

@Suite("Pre-enforcement migration enum safety", .serialized)
struct MigrationEnumSafetyTests {
    @Test("Image artifact backfill does not decode malformed enum values")
    func imageArtifactBackfillUsesRawValues() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser()
            let organization = try await builder.createOrganization()
            let project = try await builder.createProject(
                name: "enum-safety", description: "", organization: organization)
            let image = try await builder.createImage(
                name: "enum-safety", project: project, uploadedBy: user,
                storagePath: "enum-safety/disk.qcow2")

            try await removeConstraint(table: "images", column: "format", on: app.db)
            try await removeConstraint(table: "image_artifacts", column: "format", on: app.db)
            try await sql.raw(
                "UPDATE images SET format = 'future-format' WHERE id = \(bind: image.id!)"
            ).run()

            // This migration runs before EnforcePersistedEnumValues during an
            // upgrade. It must carry the raw value without asking FluentKit to
            // construct an enum, which would force-unwrap and trap.
            try await BackfillImageArtifacts().prepare(on: app.db)

            let row = try #require(
                try await sql.raw(
                    "SELECT format FROM image_artifacts WHERE image_id = \(bind: image.id!)"
                ).first()
            )
            #expect(try row.decode(column: "format", as: String.self) == "future-format")
        }
    }

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
