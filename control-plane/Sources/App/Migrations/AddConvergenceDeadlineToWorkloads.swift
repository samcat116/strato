import Fluent
import Foundation

/// The one timestamp the stuck-convergence sweep compares against (ADR 0001
/// stage 4, STR-147).
///
/// It replaces `resource_operations.created_at` + the operation's per-kind
/// budget, which stopped being available the moment lifecycle mutations
/// stopped writing operation rows. Deliberately a *deadline* rather than the
/// `lastMutationKind`/`lastMutationAt` pair the ADR sketched: with the
/// "operation already pending" mutex dropped, two mutations of different kinds
/// overlap freely, and a single last-writer-wins kind would judge an in-flight
/// create (600s) against a reboot's 120s budget and flip a healthy resource to
/// degraded. A deadline composes instead — each mutation stamps
/// `max(existing, now + budget(kind))`, so a short-budget mutation can never
/// shorten a long one's runway — and the sweep needs no kind lookup at all.
///
/// Nullable, and null means "not converging": cleared when the resource
/// converges, when a convergence attempt fails, and on every row that predates
/// this migration.
struct AddConvergenceDeadlineToWorkloads: AsyncMigration {
    func prepare(on database: Database) async throws {
        for schema in ["vms", "sandboxes"] {
            try await database.schema(schema)
                .field("convergence_deadline", .datetime)
                .update()
        }
    }

    func revert(on database: Database) async throws {
        for schema in ["vms", "sandboxes"] {
            try await database.schema(schema)
                .deleteField("convergence_deadline")
                .update()
        }
    }
}
