import Fluent
import SQLKit
import StratoShared
import Testing

import AppTestSupport

@testable import App

/// `resource_events`' database-level guards, which nothing in the type system
/// ties to the Swift enums they were derived from.
///
/// `CreateResourceEvent` builds its `CHECK` constraints from `allCases`, so a
/// fresh database always accepts every case — and an already-migrated one
/// keeps whatever list it was created with. Adding a `VMOperationKind` case
/// (the enum has grown twice already) would pass every other test, work in
/// development, and reject the insert in production. Because `ResourceEvent`
/// is written inside the mutation's transaction, that rejection rolls the
/// mutation back: a 500 on VM start, not a missing audit row.
///
/// Same gap, same remedy as `nativeAgentStatusTypeMatchesModelEnum`: assert
/// against the constraint the database actually installed, so the follow-up
/// migration is a test failure rather than an incident.
@Suite("Resource event enum constraints", .serialized)
struct ResourceEventEnumConstraintTests {

    /// Inserts one row per raw value, returning the error if any is rejected.
    private func insert(
        column: String, values: [String], on sql: any SQLDatabase
    ) async throws {
        for value in values {
            let quoted = PostgresMigrationSQL.literal(value)
            // Every column but the one under test gets a known-good value.
            let actorType = column == "actor_type" ? quoted : "'user'"
            let resourceKind = column == "resource_kind" ? quoted : "'virtual_machine'"
            let mutation = column == "mutation" ? quoted : "'boot'"
            try await sql.raw(
                """
                INSERT INTO resource_events
                    (id, actor_type, resource_kind, resource_id, mutation, created_at)
                VALUES (gen_random_uuid(), \(unsafeRaw: actorType), \(unsafeRaw: resourceKind),
                    gen_random_uuid(), \(unsafeRaw: mutation), NOW())
                """
            ).run()
        }
    }

    @Test("The installed CHECK constraints accept every case of the enums they guard")
    func constraintsAcceptEveryCase() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)

            // If any of these throws, the constraint in the database is
            // narrower than the Swift enum: add the follow-up migration
            // re-installing `resource_events`' constraint alongside
            // `resource_operations`' (see `CreateResourceEvent`).
            try await self.insert(
                column: "actor_type", values: MutationActorType.allCases.map(\.rawValue), on: sql)
            try await self.insert(
                column: "resource_kind", values: OperationResourceKind.allCases.map(\.rawValue), on: sql)
            try await self.insert(
                column: "mutation", values: VMOperationKind.allCases.map(\.rawValue), on: sql)
        }
    }

    @Test("The constraints reject a value outside the enum")
    func constraintsRejectUnknownValues() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            for column in ["actor_type", "resource_kind", "mutation"] {
                await #expect(throws: (any Error).self) {
                    try await self.insert(column: column, values: ["not_a_real_value"], on: sql)
                }
            }
        }
    }

    // MARK: - Append-only

    @Test("The database refuses to update or delete an event")
    func appendOnlyEnforcedByDatabase() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            try await self.insert(column: "mutation", values: ["boot"], on: sql)

            // The whole design rests on these rows being immutable; a
            // convention only code respects is one an incident-time `UPDATE`
            // breaks without a trace.
            await #expect(throws: (any Error).self) {
                try await sql.raw("UPDATE resource_events SET mutation = 'shutdown'").run()
            }
            await #expect(throws: (any Error).self) {
                try await sql.raw("DELETE FROM resource_events").run()
            }
            let remaining = try await ResourceEvent.query(on: app.db).count()
            #expect(remaining == 1)
        }
    }
}
