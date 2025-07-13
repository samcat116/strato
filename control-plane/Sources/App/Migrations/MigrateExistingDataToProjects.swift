import Fluent
import Foundation
import SQLKit

struct MigrateExistingDataToProjects: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Get all existing organizations
        let organizations = try await Organization.query(on: database).all()
        
        for organization in organizations {
            // Create a default project for each organization
            let defaultProject = Project(
                name: "Default Project",
                description: "Default project for \(organization.name)",
                organizationID: organization.id,
                path: "" // Will be updated below
            )
            
            try await defaultProject.save(on: database)
            
            // Update the path with the actual project ID
            if let orgId = organization.id, let projId = defaultProject.id {
                defaultProject.path = "/\(orgId.uuidString)/\(projId.uuidString)"
            }
            try await defaultProject.save(on: database)
            
            // Get all VMs that belong to this organization (via SpiceDB)
            // Since we can't query SpiceDB directly in a migration, we'll need to
            // use a different approach. For now, we'll update all VMs that don't
            // have a project_id to use the default project of the first organization.
            // A separate script will need to be run to properly associate VMs with
            // their correct organizations based on SpiceDB data.
        }
        
        // If there are any VMs without a project_id after this migration,
        // they'll need to be handled manually or via a separate script
        if let firstOrg = organizations.first,
           let firstOrgId = firstOrg.id,
           let defaultProject = try await Project.query(on: database)
            .filter(\Project.$organization.$id, .equal, firstOrgId)
            .first(),
           let defaultProjectId = defaultProject.id {
            
            // Update any VMs that don't have a project_id using raw SQL
            // since Fluent's null checks don't work well with required @Parent relationships
            if let sql = database as? SQLDatabase {
                try await sql.raw("""
                    UPDATE vms 
                    SET project_id = \(bind: defaultProjectId), environment = 'development'
                    WHERE project_id IS NULL
                    """).run()
            }
        }
        
        // Note: Making project_id required would be done in a separate migration
    }

    func revert(on database: Database) async throws {
        // Remove all default projects
        try await Project.query(on: database)
            .filter(\.$name == "Default Project")
            .delete()
        
        // Can't easily revert VM associations
    }
}