import Fluent
import Foundation

/// Persists the convergence progress the agent already reports on every
/// observed-state report, so the API can project it as a `conditions` block on
/// the resource itself (ADR 0001 stage 1, STR-142).
///
/// `convergence_phase`, `last_error`, and `failed_generation` mirror the
/// same-named fields on `ObservedVMState` / `ObservedSandboxState`. Until now
/// they were read once inside `ObservedStateApplier` — to skip an unsettled
/// observation and to fail a pending operation — and then dropped, which left
/// "why is this VM not converged, and how far along is it" answerable only by
/// polling the operation that happened to be in flight. All three are
/// nullable and purely observed: nothing outside the report writes them, and a
/// row that predates this migration simply reads as "no progress reported
/// yet".
struct AddConvergenceStateToWorkloads: AsyncMigration {
    func prepare(on database: Database) async throws {
        for schema in ["vms", "sandboxes"] {
            try await database.schema(schema)
                .field("convergence_phase", .string)
                .update()
            try await database.schema(schema)
                .field("last_error", .string)
                .update()
            try await database.schema(schema)
                .field("failed_generation", .int64)
                .update()
        }
    }

    func revert(on database: Database) async throws {
        for schema in ["vms", "sandboxes"] {
            try await database.schema(schema)
                .deleteField("convergence_phase")
                .update()
            try await database.schema(schema)
                .deleteField("last_error")
                .update()
            try await database.schema(schema)
                .deleteField("failed_generation")
                .update()
        }
    }
}
