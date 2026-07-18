import Fluent

/// IAM phase 1 (issue #477): the role/action registry tables. Contents are
/// owned by the code-side `IAMRoleRegistry` and reconciled at boot by
/// `RoleRegistrySync`; the tables exist so who-can and future tooling can
/// answer "which roles contain action X" relationally.
struct CreateIAMRoleRegistry: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("iam_roles")
            .id()
            .field("name", .string, .required)
            .field("implies", .string)
            .unique(on: "name")
            .create()

        try await database.schema("iam_role_actions")
            .id()
            .field("role", .string, .required)
            .field("action", .string, .required)
            .unique(on: "role", "action")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("iam_role_actions").delete()
        try await database.schema("iam_roles").delete()
    }
}
