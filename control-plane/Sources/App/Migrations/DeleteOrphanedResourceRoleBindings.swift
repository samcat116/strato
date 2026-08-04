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

    /// `(node_type, table holding that type's rows)`. Getting a table wrong
    /// here deletes live bindings, so each pair is the schema name declared on
    /// the model, not a guess from the type name (`virtual_machine` → `vms`).
    private static let nodeTables: [(nodeType: IAMNodeType, table: String)] = [
        (.virtualMachine, "vms"),
        (.vmSnapshot, "vm_snapshots"),
        (.sandbox, "sandboxes"),
        (.sandboxSnapshot, "sandbox_snapshots"),
        (.image, "images"),
    ]

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        for (nodeType, table) in Self.nodeTables {
            // `RETURNING id` only so the count can be logged: an operator
            // reading a surprising number wants to know which type it came
            // from. The sets are small enough that materializing them is free
            // next to the anti-join itself.
            let deleted = try await sql.raw(
                """
                DELETE FROM role_bindings
                WHERE node_type = \(bind: nodeType.rawValue)
                  AND NOT EXISTS (
                    SELECT 1 FROM \(raw: table) WHERE \(raw: table).id = role_bindings.node_id
                  )
                RETURNING id
                """
            ).all()
            if !deleted.isEmpty {
                database.logger.info(
                    "Removed orphaned role bindings",
                    metadata: [
                        "node_type": .string(nodeType.rawValue),
                        "count": .stringConvertible(deleted.count),
                    ])
            }
        }
    }

    /// Nothing to restore: the rows named nodes that no longer exist, and their
    /// contents were not preserved. Reverting is a no-op rather than an error
    /// so it does not block a rollback of the migrations around it.
    func revert(on database: Database) async throws {}
}
