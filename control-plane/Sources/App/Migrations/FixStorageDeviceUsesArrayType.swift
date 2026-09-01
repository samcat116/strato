import Fluent
import SQLKit

/// Aligns the storage-device usage column with Fluent's encoding of
/// `[StorageDeviceUse]`, which PostgreSQL receives as a native `text[]`.
struct FixStorageDeviceUsesArrayType: AsyncMigration {
    var name: String { "App.FixStorageDeviceUsesArrayType" }

    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            throw FixStorageDeviceUsesArrayTypeError.postgresRequired
        }

        let columnType = try await sql.raw(
            """
            SELECT udt_name
            FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND table_name = 'storage_devices'
              AND column_name = 'uses'
            """
        ).first(decodingColumn: "udt_name", as: String.self)
        switch columnType {
        case "_text":
            return
        case "_jsonb":
            break
        default:
            throw FixStorageDeviceUsesArrayTypeError.unexpectedColumnType(columnType)
        }

        try await sql.raw(
            """
            CREATE OR REPLACE FUNCTION pg_temp.storage_device_uses_to_text(source jsonb[])
            RETURNS text[]
            LANGUAGE sql
            IMMUTABLE
            STRICT
            AS $str300$
                SELECT COALESCE(
                    array_agg(item #>> '{}' ORDER BY ordinal),
                    '{}'::text[]
                )
                FROM unnest(source) WITH ORDINALITY AS entries(item, ordinal)
            $str300$
            """
        ).run()

        try await sql.raw(
            """
            ALTER TABLE storage_devices
                ALTER COLUMN uses DROP DEFAULT,
                ALTER COLUMN uses TYPE text[]
                    USING pg_temp.storage_device_uses_to_text(uses),
                ALTER COLUMN uses SET DEFAULT '{}'::text[]
            """
        ).run()
    }

    /// Reverting would restore the incompatible type and make inventory writes
    /// fail again, so the compatible representation is intentionally retained.
    func revert(on database: Database) async throws {}
}

private enum FixStorageDeviceUsesArrayTypeError: Error, CustomStringConvertible {
    case postgresRequired
    case unexpectedColumnType(String?)

    var description: String {
        switch self {
        case .postgresRequired:
            return "The storage-device usage array migration requires PostgreSQL"
        case .unexpectedColumnType(let type):
            return "storage_devices.uses must be jsonb[] or text[], not \(type ?? "a missing column")"
        }
    }
}
