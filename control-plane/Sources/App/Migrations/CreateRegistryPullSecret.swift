import Fluent

/// Creates `registry_pull_secrets` (issue #414): per-project credentials for
/// private OCI registries, with the secret encrypted at rest. One credential
/// per (project, registry) — the unique constraint is what makes
/// image-to-credential matching at sync assembly deterministic.
struct CreateRegistryPullSecret: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("registry_pull_secrets")
            .id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("registry", .string, .required)
            .field("username", .string, .required)
            .field("secret", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "project_id", "registry")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("registry_pull_secrets").delete()
    }
}
