import Fluent
import FluentPostgresDriver
import SQLKit

/// Indexes the folder tree's materialized `path` for prefix matching (issue #692).
///
/// `OrganizationalUnit.descendants()` and every folder-scoped quota measurement
/// now find a subtree with `path LIKE '<parent path>/%'`. A plain B-tree index
/// cannot serve that under a non-C collation — Postgres only uses one for `LIKE`
/// when the index is built with `varchar_pattern_ops`, which orders by raw byte
/// value and so matches how a prefix comparison works.
///
/// This index is the other half of `AddHotPathIndexes` (issue #693), which left
/// it out while the descendant lookup was still a leading-wildcard
/// `LIKE '%<uuid>%'` that no index could have served.
struct AddFolderPathIndex: AsyncMigration {
    static let indexes: [(name: String, definition: String)] = [
        ("idx_organizational_units_path_prefix", "organizational_units (path varchar_pattern_ops)")
    ]

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        for index in Self.indexes {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS \(unsafeRaw: index.name) ON \(unsafeRaw: index.definition)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        for index in Self.indexes {
            try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: index.name)").run()
        }
    }
}
