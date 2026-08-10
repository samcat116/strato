import Fluent
import SQLKit

/// STR-227: backfill the one canonical credential restriction, require it on
/// every bearer credential row, and remove the legacy authorization system.
///
/// Historical scope arrays map exactly as the STR-115 read shim did:
/// `write`/`admin` are unrestricted, `read` is the symbolic read action, and an
/// empty or wholly malformed array denies everything. A recognized value wins
/// over unrelated malformed entries, matching the old `compactMap` behavior.
struct RemoveLegacyCredentialScopes: AsyncMigration {
    struct UnsupportedDatabase: Error {}

    private static let tables = [APIKey.schema, CLISession.schema, DeviceAuthorization.schema]

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw UnsupportedDatabase() }

        for table in Self.tables {
            try await sql.raw(
                """
                UPDATE \(ident: table)
                SET restriction_actions = CASE
                    WHEN scopes && ARRAY['write', 'admin']::text[] THEN ARRAY['*']::text[]
                    WHEN scopes && ARRAY['read']::text[] THEN ARRAY['read']::text[]
                    ELSE ARRAY[]::text[]
                END
                WHERE restriction_actions IS NULL
                """
            ).run()
            try await sql.raw(
                "ALTER TABLE \(ident: table) ALTER COLUMN restriction_actions SET NOT NULL"
            ).run()
            try await sql.raw("ALTER TABLE \(ident: table) DROP COLUMN scopes").run()
        }
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw UnsupportedDatabase() }

        for table in Self.tables {
            try await sql.raw("ALTER TABLE \(ident: table) ADD COLUMN scopes text[]").run()
            // Exact unrestricted/read-only restrictions retain their historical
            // spelling. Anything the old vocabulary cannot express fails
            // closed on a full downgrade instead of widening to account scope.
            try await sql.raw(
                """
                UPDATE \(ident: table)
                SET scopes = CASE
                    WHEN restriction_node_type IS NULL
                         AND restriction_node_id IS NULL
                         AND restriction_actions = ARRAY['*']::text[]
                        THEN ARRAY['write']::text[]
                    WHEN restriction_node_type IS NULL
                         AND restriction_node_id IS NULL
                         AND restriction_actions = ARRAY['read']::text[]
                        THEN ARRAY['read']::text[]
                    ELSE ARRAY[]::text[]
                END
                """
            ).run()
            try await sql.raw("ALTER TABLE \(ident: table) ALTER COLUMN scopes SET NOT NULL").run()
            try await sql.raw(
                "ALTER TABLE \(ident: table) ALTER COLUMN restriction_actions DROP NOT NULL"
            ).run()
        }
    }
}
