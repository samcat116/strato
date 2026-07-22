import Fluent
import Foundation
import SQLKit

struct MigrateExistingDataToProjects: AsyncMigration {
    /// Column snapshot of `projects` as it exists at this point in the migration
    /// chain: `environments` is still the JSON-encoded text column it was created
    /// as, and only becomes a native `text[]` in `ConvertProjectEnvironmentsToArray`.
    /// Querying the live `Project` model here would bind a Swift array against a
    /// text column.
    private final class ProjectSnapshot: Model, @unchecked Sendable {
        static let schema = "projects"

        @ID(key: .id)
        var id: UUID?

        @Field(key: "name")
        var name: String

        @Field(key: "description")
        var description: String

        @OptionalParent(key: "organization_id")
        var organization: Organization?

        @OptionalField(key: "organizational_unit_id")
        var organizationalUnitID: UUID?

        @Field(key: "path")
        var path: String

        @Field(key: "default_environment")
        var defaultEnvironment: String

        @Field(key: "environments")
        var environmentsJSON: String

        init() {}

        init(name: String, description: String, organizationID: UUID?, path: String) {
            self.name = name
            self.description = description
            self.$organization.id = organizationID
            self.organizationalUnitID = nil
            self.path = path
            self.defaultEnvironment = "development"
            self.environmentsJSON = #"["development","staging","production"]"#
        }
    }

    func prepare(on database: Database) async throws {
        // Get all existing organizations
        let organizations = try await Organization.query(on: database).all()

        for organization in organizations {
            // Create a default project for each organization
            let defaultProject = ProjectSnapshot(
                name: "Default Project",
                description: "Default project for \(organization.name)",
                organizationID: organization.id,
                path: ""  // Will be updated below
            )

            try await defaultProject.save(on: database)

            // Update the path with the actual project ID
            if let orgId = organization.id, let projId = defaultProject.id {
                defaultProject.path = "/\(orgId.uuidString)/\(projId.uuidString)"
            }
            try await defaultProject.save(on: database)

            // VM→organization ownership lived in the then-authorization engine
            // rather than a relational column, so this migration could not
            // resolve it. VMs without a project_id fall back to the first
            // organization's default project below.
        }

        // If there are any VMs without a project_id after this migration,
        // they'll need to be handled manually or via a separate script
        if let firstOrg = organizations.first,
            let firstOrgId = firstOrg.id,
            let defaultProject = try await ProjectSnapshot.query(on: database)
                .filter(\ProjectSnapshot.$organization.$id, .equal, firstOrgId)
                .first(),
            let defaultProjectId = defaultProject.id
        {

            // Update any VMs that don't have a project_id using raw SQL
            // since Fluent's null checks don't work well with required @Parent relationships
            if let sql = database as? SQLDatabase {
                try await sql.raw(
                    """
                    UPDATE vms
                    SET project_id = \(bind: defaultProjectId), environment = 'development'
                    WHERE project_id IS NULL
                    """
                ).run()
            }
        }

        // Note: Making project_id required would be done in a separate migration
    }

    func revert(on database: Database) async throws {
        // Remove all default projects
        try await ProjectSnapshot.query(on: database)
            .filter(\.$name == "Default Project")
            .delete()

        // Can't easily revert VM associations
    }
}
