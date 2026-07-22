import Fluent

// IAM workload principals (issue #491): service accounts as project-scoped
// resources and machine principals, plus the workload registry mapping
// SPIFFE IDs to registered principals.

struct CreateServiceAccount: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("service_accounts")
            .id()
            .field("name", .string, .required)
            .field("description", .string, .required)
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "project_id", "name")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("service_accounts").delete()
    }
}

struct CreateWorkloadRegistration: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("workload_registrations")
            .id()
            .field("spiffe_id", .string, .required)
            .field("kind", .string, .required)
            .field("agent_name", .string)
            .field(
                "service_account_id", .uuid,
                .references("service_accounts", "id", onDelete: .cascade)
            )
            .field(
                "organization_id", .uuid,
                .references("organizations", "id", onDelete: .cascade)
            )
            .field("display_name", .string)
            .field("created_by", .uuid)
            .field("created_at", .datetime)
            // The registry is a function from SPIFFE ID to principal: one
            // identity can never name two principals.
            .unique(on: "spiffe_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("workload_registrations").delete()
    }
}
