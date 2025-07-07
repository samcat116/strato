import Testing
import Vapor
import Fluent
import FluentSQLiteDriver
import VaporTesting
@testable import App

@Suite("Manual Schema Tests")
final class ManualSchemaTests: BaseTestCase {
    
    /// Manually create just the tables we need for testing
    func setupTestSchema(on db: Database) async throws {
        // Create users table
        try await db.schema("users")
            .id()
            .field("username", .string, .required)
            .field("email", .string, .required)
            .field("display_name", .string, .required)
            .field("current_organization_id", .uuid)
            .field("is_system_admin", .bool, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "username")
            .unique(on: "email")
            .create()
        
        // Create organizations table
        try await db.schema("organizations")
            .id()
            .field("name", .string, .required)
            .field("description", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "name")
            .create()
        
        // Create user_organizations table
        try await db.schema("user_organizations")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("organization_id", .uuid, .required, .references("organizations", "id", onDelete: .cascade))
            .field("role", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "organization_id")
            .create()
    }
    
    @Test("Manual schema setup works")
    func testManualSchemaSetup() async throws {
        try await withApp { app in
            // Schema is already created by auto-migration
            // Just test basic operations
            
            // Try to create a user
            let user = User(
                username: "testuser",
                email: "test@example.com",
                displayName: "Test User",
                isSystemAdmin: false
            )
            try await user.save(on: app.db)
            
            // Verify user was saved
            let savedUser = try await User.query(on: app.db)
                .filter(\.$username == "testuser")
                .first()
            
            #expect(savedUser != nil)
            #expect(savedUser?.email == "test@example.com")
        }
    }
    
    @Test("Manual setup with organization relationship")
    func testOrganizationRelationship() async throws {
        try await withApp { app in
            // Schema is already created by auto-migration
            // Just test relationships
            
            // Create user and organization
            let user = User(
                username: "testuser",
                email: "test@example.com",
                displayName: "Test User",
                isSystemAdmin: false
            )
            try await user.save(on: app.db)
            
            let org = Organization(
                name: "Test Organization",
                description: "Test organization"
            )
            try await org.save(on: app.db)
            
            // Create relationship
            let userOrg = UserOrganization(
                userID: user.id!,
                organizationID: org.id!,
                role: "admin"
            )
            try await userOrg.save(on: app.db)
            
            // Verify relationship
            let relationship = try await UserOrganization.query(on: app.db)
                .filter(\.$user.$id == user.id!)
                .filter(\.$organization.$id == org.id!)
                .first()
            
            #expect(relationship != nil)
            #expect(relationship?.role == "admin")
        }
    }
}