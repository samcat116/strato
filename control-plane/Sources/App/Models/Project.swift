import Fluent
import Vapor
import Foundation

final class Project: Model, @unchecked Sendable {
    static let schema = "projects"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "description")
    var description: String

    // Project can belong to either an Organization directly or to an OU
    @OptionalParent(key: "organization_id")
    var organization: Organization?

    @OptionalParent(key: "organizational_unit_id")
    var organizationalUnit: OrganizationalUnit?

    // Path for efficient hierarchy queries
    @Field(key: "path")
    var path: String

    // Default environment for new resources
    @Field(key: "default_environment")
    var defaultEnvironment: String

    // Available environments stored as JSON string for SQLite compatibility
    @Field(key: "environments")
    var environmentsJSON: String
    
    // Computed property for array access
    var environments: [String] {
        get {
            guard let data = environmentsJSON.data(using: .utf8),
                  let array = try? JSONDecoder().decode([String].self, from: data) else {
                return ["development"]
            }
            return array
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let string = String(data: data, encoding: .utf8) else {
                environmentsJSON = "[\"development\"]"
                return
            }
            environmentsJSON = string
        }
    }

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    // Relationships
    @Children(for: \.$project)
    var vms: [VM]

    @Children(for: \.$project)
    var resourceQuotas: [ResourceQuota]

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        description: String,
        organizationID: UUID? = nil,
        organizationalUnitID: UUID? = nil,
        path: String,
        defaultEnvironment: String = "development",
        environments: [String] = ["development", "staging", "production"]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.$organization.id = organizationID
        self.$organizationalUnit.id = organizationalUnitID
        self.path = path
        self.defaultEnvironment = defaultEnvironment
        self.environments = environments
    }
}

extension Project: Content {}

extension Project {
    struct Public: Content {
        let id: UUID?
        let name: String
        let description: String
        let organizationId: UUID?
        let organizationalUnitId: UUID?
        let path: String
        let defaultEnvironment: String
        let environments: [String]
        let createdAt: Date?
    }

    func asPublic() -> Public {
        return Public(
            id: self.id,
            name: self.name,
            description: self.description,
            organizationId: self.$organization.id,
            organizationalUnitId: self.$organizationalUnit.id,
            path: self.path,
            defaultEnvironment: self.defaultEnvironment,
            environments: self.environments,
            createdAt: self.createdAt
        )
    }
}

// MARK: - Helper Methods

extension Project {
    /// Builds the path string for this project based on its hierarchy
    func buildPath(on db: Database) async throws -> String {
        var pathComponents: [String] = []
        
        // If project belongs to an OU, get the OU's path
        if let ouId = self.$organizationalUnit.id {
            if let ou = try await OrganizationalUnit.find(ouId, on: db) {
                // Remove trailing OU ID from path as we'll add project ID
                let ouPath = ou.path
                let pathParts = ouPath.split(separator: "/").map(String.init)
                pathComponents = pathParts
            }
        } else if let orgId = self.$organization.id {
            // Direct organization child
            pathComponents.append(orgId.uuidString)
        }
        
        // Add project ID if available
        if let projectId = self.id {
            pathComponents.append(projectId.uuidString)
        }
        
        return "/" + pathComponents.joined(separator: "/")
    }
    
    /// Gets the root organization ID for this project
    func getRootOrganizationId(on db: Database) async throws -> UUID? {
        if let orgId = self.$organization.id {
            return orgId
        }
        
        if let ouId = self.$organizationalUnit.id,
           let ou = try await OrganizationalUnit.find(ouId, on: db) {
            return ou.$organization.id
        }
        
        return nil
    }
    
    /// Validates that an environment exists in this project
    func hasEnvironment(_ environment: String) -> Bool {
        return environments.contains(environment)
    }
    
    /// Adds a new environment to the project
    func addEnvironment(_ environment: String) {
        if !environments.contains(environment) {
            environments.append(environment)
        }
    }
    
    /// Removes an environment from the project (if not the default)
    func removeEnvironment(_ environment: String) -> Bool {
        guard environment != defaultEnvironment,
              let index = environments.firstIndex(of: environment) else {
            return false
        }
        environments.remove(at: index)
        return true
    }
}

// MARK: - Validations

extension Project {
    func validate() throws {
        // Ensure project belongs to either org or OU, but not both
        if self.$organization.id != nil && self.$organizationalUnit.id != nil {
            throw Abort(.badRequest, reason: "Project cannot belong to both an organization and an organizational unit")
        }
        
        if self.$organization.id == nil && self.$organizationalUnit.id == nil {
            throw Abort(.badRequest, reason: "Project must belong to either an organization or an organizational unit")
        }
        
        // Ensure default environment exists in environments list
        if !environments.contains(defaultEnvironment) {
            throw Abort(.badRequest, reason: "Default environment must be in the environments list")
        }
        
        // Ensure at least one environment exists
        if environments.isEmpty {
            throw Abort(.badRequest, reason: "Project must have at least one environment")
        }
    }
}

// MARK: - DTOs

struct CreateProjectRequest: Content {
    let name: String
    let description: String
    let organizationalUnitId: UUID?
    let defaultEnvironment: String?
    let environments: [String]?
}

struct UpdateProjectRequest: Content {
    let name: String?
    let description: String?
    let defaultEnvironment: String?
    let environments: [String]?
}

struct ProjectResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let organizationId: UUID?
    let organizationalUnitId: UUID?
    let path: String
    let defaultEnvironment: String
    let environments: [String]
    let createdAt: Date?
    let vmCount: Int?
    let quotas: [ResourceQuotaResponse]?

    init(from project: Project, vmCount: Int? = nil, quotas: [ResourceQuotaResponse]? = nil) {
        self.id = project.id
        self.name = project.name
        self.description = project.description
        self.organizationId = project.$organization.id
        self.organizationalUnitId = project.$organizationalUnit.id
        self.path = project.path
        self.defaultEnvironment = project.defaultEnvironment
        self.environments = project.environments
        self.createdAt = project.createdAt
        self.vmCount = vmCount
        self.quotas = quotas
    }
}

struct ProjectEnvironmentRequest: Content {
    let environment: String
}

struct ProjectStatsResponse: Content {
    let totalVMs: Int
    let vmsByEnvironment: [String: Int]
    let resourceUsage: ResourceUsageResponse
}