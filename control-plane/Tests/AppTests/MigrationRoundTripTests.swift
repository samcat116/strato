import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// Validates that the full migration set applies *and* reverses cleanly against
/// the configured database engine.
///
/// This is the guard for issue #195: run with `STRATO_TEST_DATABASE=postgres`
/// (as CI's Postgres matrix leg does) and it exercises every migration's
/// `prepare` and `revert` — including Postgres-specific SQL and engine-specific
/// branches — against the real engine production uses, not just SQLite.
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
}
