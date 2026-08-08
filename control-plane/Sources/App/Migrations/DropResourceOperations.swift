import Fluent
import SQLKit

/// Drops the `resource_operations` table (ADR 0001 stage 11, STR-152).
///
/// The table was the durable record of one asynchronous mutation: a `pending`
/// row inserted with the desired-state change, completed from the agent's
/// correlated response, and failed by a cluster-singleton sweep when no
/// response came. Every one of those facts is now carried by the resource
/// itself — `observedGeneration` against `generation`, plus
/// `conditions.degraded` — or by the append-only `resource_events` trail, and
/// `OperationFacade` synthesizes the old wire shape from the two. Nothing has
/// written a row since stage 9 (STR-151) converted the last verb.
///
/// This is the whole schema change, and it deliberately has no deprecation
/// window: the migrations that built the table are deleted rather than
/// reverted, so a fresh database never creates it and an existing one drops it
/// here. `IF EXISTS` is what makes both paths the same statement. `CASCADE`
/// covers the three indexes and the enum `CHECK` constraints
/// `EnforcePersistedEnumValues` installed on it, none of which anything else
/// references.
///
/// `revert` is a no-op rather than a re-create: restoring an empty table with
/// no writers and no readers would be theatre, and the rows are gone either
/// way.
struct DropResourceOperations: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let sql = try PostgresMigrationSQL.database(database)
        try await PostgresMigrationSQL.execute(
            "DROP TABLE IF EXISTS \"resource_operations\" CASCADE", on: sql)
    }

    func revert(on database: any Database) async throws {}
}
