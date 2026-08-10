import Fluent
import SQLKit

/// Persists the latest typed dependency-health snapshot carried by agent
/// registration and heartbeats (STR-237).
struct AddAgentDependencyObservations: AsyncMigration {
    func prepare(on database: Database) async throws {
        let emptyArrayDefault =
            (database as? SQLDatabase)?.dialect.name == "postgresql"
            ? "DEFAULT '{}'"
            : "DEFAULT '[]'"
        try await database.schema("agents")
            .field(
                "dependency_observations", .array(of: .json), .required,
                .custom(emptyArrayDefault)
            )
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents")
            .deleteField("dependency_observations")
            .update()
    }
}
