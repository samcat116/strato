import Fluent
import SQLKit

/// The `finalizers` list on VMs and sandboxes (ADR 0001, stage 3): the tokens
/// a terminating resource still owes cleanup for, and the reason its row now
/// provably outlives the `DELETE` that marked it absent.
///
/// `text[]` rather than JSON so a participant can clear its own token with a
/// single atomic `array_remove`, without a read-modify-write that two
/// participants (or two replicas) could interleave. `NOT NULL DEFAULT '{}'`:
/// an empty list is "nothing outstanding", which is what every existing row is.
///
/// Deletions already in flight across the upgrade are backfilled with
/// `agent.absent` so the invariant "a terminating placed workload is waiting on
/// its agent" holds for them too. Rows that miss the backfill are not stranded
/// — an empty list reaps on the participant's next trigger — but they would
/// briefly claim to be waiting on nothing.
struct AddFinalizersToWorkloads: AsyncMigration {
    private static let column = "finalizers"

    func prepare(on database: any Database) async throws {
        // Postgres spells an empty array `'{}'` (the `agents.hypervisors`
        // precedent).
        let emptyArrayDefault =
            (database as? any SQLDatabase)?.dialect.name == "postgresql"
            ? "DEFAULT '{}'"
            : "DEFAULT '[]'"

        for schema in [VM.schema, Sandbox.schema] {
            try await database.schema(schema)
                .field(
                    .init(stringLiteral: Self.column), .array(of: .string), .required,
                    .custom(emptyArrayDefault)
                )
                .update()
        }

        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else { return }
        for schema in [VM.schema, Sandbox.schema] {
            try await sql.raw(
                """
                UPDATE \(ident: schema)
                SET finalizers = ARRAY[\(bind: ResourceFinalizer.agentAbsent.rawValue)]
                WHERE desired_status::text = 'Absent' AND hypervisor_id IS NOT NULL
                """
            ).run()
        }
    }

    func revert(on database: any Database) async throws {
        for schema in [VM.schema, Sandbox.schema] {
            try await database.schema(schema)
                .deleteField(.init(stringLiteral: Self.column))
                .update()
        }
    }
}
