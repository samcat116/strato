import ControlPlanePostgres
import StratoShared
import Testing

import AppTestSupport

@testable import App

/// `resource_events`' database-level guards, which nothing in the type system
/// ties to the Swift enums they were derived from.
///
/// The baseline's `CHECK` constraints are derived from these enums, so a fresh
/// database must accept every case. Adding a `VMOperationKind` case
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
        column: String, values: [String], on sql: PostgresStoreContext
    ) async throws {
        for value in values {
            let quoted = "'\(value.replacingOccurrences(of: "'", with: "''"))'"
            // Every column but the one under test gets a known-good value.
            let actorType = column == "actor_type" ? quoted : "'user'"
            let resourceKind = column == "resource_kind" ? quoted : "'virtual_machine'"
            let mutation = column == "mutation" ? quoted : "'boot'"
            let phase = column == "phase" ? quoted : "'requested'"
            try await sql.raw(
                """
                INSERT INTO resource_events
                    (id, actor_type, resource_kind, resource_id, mutation, phase, created_at)
                VALUES (gen_random_uuid(), \(unsafeRaw: actorType), \(unsafeRaw: resourceKind),
                    gen_random_uuid(), \(unsafeRaw: mutation), \(unsafeRaw: phase), NOW())
                """
            ).run()
        }
    }

    @Test("The installed CHECK constraints accept every case of the enums they guard")
    func constraintsAcceptEveryCase() async throws {
        try await withTestApp { app in
            let sql = try #require(Optional(app.testPostgres))

            // If any of these throws, the constraint in the database is
            // narrower than the Swift enum: add a follow-up migration that
            // re-installs both affected constraints.
            try await self.insert(
                column: "actor_type", values: MutationActorType.allCases.map(\.rawValue), on: sql)
            try await self.insert(
                column: "resource_kind", values: OperationResourceKind.allCases.map(\.rawValue), on: sql)
            try await self.insert(
                column: "mutation", values: VMOperationKind.allCases.map(\.rawValue), on: sql)
            try await self.insert(
                column: "phase", values: ResourceEventPhase.allCases.map(\.rawValue), on: sql)
        }
    }

    @Test("The constraints reject a value outside the enum")
    func constraintsRejectUnknownValues() async throws {
        try await withTestApp { app in
            let sql = try #require(Optional(app.testPostgres))
            for column in ["actor_type", "resource_kind", "mutation", "phase"] {
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
            let sql = try #require(Optional(app.testPostgres))
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
            let remaining = try await ResourceEvent.count(on: app.testPostgres)
            #expect(remaining == 1)
        }
    }
}
