import Fluent
import Foundation

/// Adds workload-only observability for steady-state convergence failures
/// (STR-123). `last_error_at` is API-visible through `conditions.degraded`;
/// `divergence_detected_at` is an internal compare-and-swap claim that keeps
/// multiple heartbeat sweep replicas from warning about the same episode.
struct AddWorkloadConvergenceObservability: AsyncMigration {
    func prepare(on database: Database) async throws {
        for schema in ["vms", "sandboxes"] {
            try await database.schema(schema)
                .field("last_error_at", .datetime)
                .field("divergence_detected_at", .datetime)
                .update()
        }
    }

    func revert(on database: Database) async throws {
        for schema in ["vms", "sandboxes"] {
            try await database.schema(schema)
                .deleteField("divergence_detected_at")
                .deleteField("last_error_at")
                .update()
        }
    }
}
