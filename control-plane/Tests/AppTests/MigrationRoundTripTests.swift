import SQLKit
import Testing
import Vapor
import Fluent
import VaporTesting
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

            for index in AddHotPathIndexes.indexes + AddFolderPathIndex.indexes {
                let exists = present.contains(index.name)
                #expect(exists, "missing index \(index.name)")
            }
        }
    }
}
