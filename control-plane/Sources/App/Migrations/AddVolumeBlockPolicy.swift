import Fluent
import SQLKit

/// Requested and observed QEMU block-device policy (STR-269).
///
/// The non-optimized mode is backfilled explicitly so upgrading a fleet cannot
/// turn direct I/O or host caching on by accident. Fresh databases already
/// contain the columns in `CurrentSchema.sql`, hence the idempotent statements.
struct AddVolumeBlockPolicy: AsyncMigration {
    var name: String { "App.AddVolumeBlockPolicy" }

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw AddVolumeBlockPolicyError.sqlDatabaseRequired
        }
        try await sql.raw(
            "ALTER TABLE volumes ADD COLUMN IF NOT EXISTS block_mode text NOT NULL DEFAULT 'conservative'"
        ).run()
        try await sql.raw(
            "ALTER TABLE volumes ADD COLUMN IF NOT EXISTS applied_block_policy jsonb"
        ).run()
        try await sql.raw(
            "ALTER TABLE volumes DROP CONSTRAINT IF EXISTS ck_volumes_block_mode_enum"
        ).run()
        try await sql.raw(
            """
            ALTER TABLE volumes
            ADD CONSTRAINT ck_volumes_block_mode_enum
            CHECK (block_mode IN ('conservative', 'direct', 'cachedShared'))
            """
        ).run()
    }

    func revert(on database: any Database) async throws {}
}

private enum AddVolumeBlockPolicyError: Error {
    case sqlDatabaseRequired
}
