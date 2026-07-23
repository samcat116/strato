import Fluent
import Vapor
import Foundation

final class Organization: Model, @unchecked Sendable {
    static let schema = "organizations"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "description")
    var description: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    // Relationships
    @Siblings(through: UserOrganization.self, from: \.$organization, to: \.$user)
    var users: [User]

    @Children(for: \.$organization)
    var organizationalUnits: [OrganizationalUnit]

    @Children(for: \.$organization)
    var projects: [Project]

    @Children(for: \.$organization)
    var resourceQuotas: [ResourceQuota]

    @Children(for: \.$organization)
    var groups: [Group]

    @Children(for: \.$organization)
    var oidcProviders: [OIDCProvider]

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        description: String
    ) {
        self.id = id
        self.name = name
        self.description = description
    }
}

extension Organization: Content {}

extension Organization {
    struct Public: Content {
        let id: UUID?
        let name: String
        let description: String
        let createdAt: Date?
    }

    func asPublic() -> Public {
        return Public(
            id: self.id,
            name: self.name,
            description: self.description,
            createdAt: self.createdAt
        )
    }
}

// MARK: - User-Organization Relationship (Many-to-Many)

final class UserOrganization: Model, @unchecked Sendable {
    static let schema = "user_organizations"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Parent(key: "organization_id")
    var organization: Organization

    @Field(key: "role")
    var role: String  // "admin" or "member"

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        organizationID: UUID,
        role: String = "member"
    ) {
        self.id = id
        self.$user.id = userID
        self.$organization.id = organizationID
        self.role = role
    }
}

extension UserOrganization: Content {}

// MARK: - DTOs

struct CreateOrganizationRequest: Content {
    let name: String
    // Optional: the frontend omits this when the description field is left
    // blank. Decoding a required field here 400s the whole create request.
    let description: String?
}

struct UpdateOrganizationRequest: Content {
    let name: String?
    let description: String?
}

struct OrganizationResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let createdAt: Date?
    let userRole: String?

    init(from organization: Organization, userRole: String? = nil) {
        self.id = organization.id
        self.name = organization.name
        self.description = organization.description
        self.createdAt = organization.createdAt
        self.userRole = userRole
    }
}

struct OrganizationMemberResponse: Content {
    let id: UUID?
    let username: String
    let displayName: String
    let email: String
    /// The stored membership role: a legacy literal (`admin`/`member`) or, for
    /// a role granted by IAM name or id, the role's `iam_roles` id (issue #608).
    let role: String
    /// The role's human-readable name — the literal for legacy values, the row
    /// name for a UUID, "(deleted role)" for a dangling id (issue #608).
    let roleDisplayName: String
    let joinedAt: Date?
}

// MARK: - Helper Methods

extension Organization {
    /// Get all projects in this organization (including those in OUs)
    func getAllProjects(on db: Database) async throws -> [Project] {
        // Get direct projects
        let directProjects = try await self.$projects.query(on: db).all()

        // Get all OUs and their projects recursively
        let ous = try await self.$organizationalUnits.query(on: db).all()
        var allProjects = directProjects

        for ou in ous {
            let ouProjects = try await ou.getAllProjects(on: db)
            allProjects.append(contentsOf: ouProjects)
        }

        return allProjects
    }

    /// Get all VMs in this organization (across all projects)
    func getAllVMs(on db: Database) async throws -> [VM] {
        let projects = try await getAllProjects(on: db)
        var allVMs: [VM] = []

        for project in projects {
            let vms = try await project.$vms.query(on: db).all()
            allVMs.append(contentsOf: vms)
        }

        return allVMs
    }

    /// Get resource usage across the organization
    func getResourceUsage(on db: Database) async throws -> ResourceUsageResponse {
        let vms = try await getAllVMs(on: db)

        let totalVCPUs = vms.reduce(0) { $0 + $1.cpu }
        let totalMemory = vms.reduce(0) { $0 + $1.memory }
        let totalStorage = vms.reduce(0) { $0 + $1.disk }

        return ResourceUsageResponse(
            totalVCPUs: totalVCPUs,
            totalMemoryGB: Double(totalMemory) / 1024 / 1024 / 1024,
            totalStorageGB: Double(totalStorage) / 1024 / 1024 / 1024,
            totalVMs: vms.count
        )
    }

}

extension OrganizationalUnit {
    /// Get all projects in this OU and its descendants
    func getAllProjects(on db: Database) async throws -> [Project] {
        // Get direct projects
        let directProjects = try await self.$projects.query(on: db).all()

        // Get all child OUs and their projects recursively
        let childOUs = try await self.$childOUs.query(on: db).all()
        var allProjects = directProjects

        for childOU in childOUs {
            let childProjects = try await childOU.getAllProjects(on: db)
            allProjects.append(contentsOf: childProjects)
        }

        return allProjects
    }
}
