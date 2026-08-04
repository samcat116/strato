import Fluent
import SQLKit

/// Deletes `role_bindings` rows whose node no longer exists (STR-112).
///
/// VM and sandbox creation write a creator binding, but neither delete path
/// revoked it, so every VM or sandbox ever deleted left its binding behind —
/// and with it the bindings of the snapshots that cascade away with the row.
/// Image deletion had the same gap. Those paths now revoke on delete
/// (`ResourceBindingCleanup`); this clears what they already leaked.
///
/// The rows are inert — an orphan names a node id no walk can resolve, so it
/// grants nothing and the ancestor walk never reaches it — but on the two
/// highest-churn resource types they accumulate without bound, and they are
/// noise in reverse lookups (`WhoCanService`) and binding listings.
///
/// Scoped to the five node types whose leak this change fixes. Other types can
/// still be orphaned by a *cascade* (deleting a project takes its volumes,
/// networks, DNS zones and images with it while revoking only the project's own
/// bindings); that is a separate gap, and sweeping types whose delete paths are
/// still leaking would only hide it.
struct DeleteOrphanedResourceRoleBindings: AsyncMigration {
    struct UnsupportedDatabase: Error {}

    /// The types swept. Each one's table comes from `IAMNodeType.table` — the
    /// schema name declared on the model — rather than being spelled again
    /// here: naming the wrong table is the one mistake that would delete live
    /// bindings instead of dead ones.
    private static let sweptNodeTypes: [IAMNodeType] = [
        .virtualMachine, .vmSnapshot, .sandbox, .sandboxSnapshot, .image,
    ]

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        for nodeType in Self.sweptNodeTypes {
            let table = nodeType.table
            // Counted in the database rather than by materializing the deleted
            // rows: an operator reading a surprising number wants to know which
            // type it came from, but a deployment that has been leaking for
            // years has an unbounded number of orphans, and this runs at boot
            // before the replica serves traffic.
            let removed =
                try await sql.raw(
                    """
                    WITH deleted AS (
                      DELETE FROM role_bindings
                      WHERE node_type = \(bind: nodeType.rawValue)
                        AND NOT EXISTS (
                          SELECT 1 FROM \(raw: table) WHERE \(raw: table).id = role_bindings.node_id
                        )
                      RETURNING 1
                    )
                    SELECT count(*) AS removed FROM deleted
                    """
                ).first(decodingColumn: "removed", as: Int.self) ?? 0
            if removed > 0 {
                database.logger.info(
                    "Removed orphaned role bindings",
                    metadata: [
                        "node_type": .string(nodeType.rawValue),
                        "count": .stringConvertible(removed),
                    ])
            }
        }
    }

    /// Nothing to restore: the rows named nodes that no longer exist, and their
    /// contents were not preserved. Reverting is a no-op rather than an error
    /// so it does not block a rollback of the migrations around it.
    func revert(on database: Database) async throws {}
}
