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

    // Available environments
    @Field(key: "environments")
    var environments: [String]

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
        var parentPath = ""

        // If project belongs to an OU, get the OU's path
        if let ouId = self.$organizationalUnit.id {
            if let ou = try await OrganizationalUnit.find(ouId, on: db) {
                parentPath = ou.path
            }
        } else if let orgId = self.$organization.id {
            // Direct organization child
            parentPath = OrganizationalUnit.organizationPath(orgId)
        }

        guard let projectId = self.id else {
            return parentPath.isEmpty ? "/" : parentPath
        }
        return Project.path(under: parentPath, projectID: projectId)
    }

    /// The materialized path a project carries beneath a parent whose own
    /// materialized path is `parentPath` — a folder's `path`, or
    /// ``OrganizationalUnit/organizationPath(_:)`` for a project attached
    /// straight to the organization.
    ///
    /// Split out from ``buildPath(on:)`` so callers that already hold the parent
    /// path (the folder-move rewrite, the hierarchy validator) derive it the same
    /// way instead of re-reading the parent row per project.
    static func path(under parentPath: String, projectID: UUID) -> String {
        "\(parentPath)/\(projectID.uuidString)"
    }

    /// Gets the root organization ID for this project
    func getRootOrganizationId(on db: Database) async throws -> UUID? {
        if let orgId = self.$organization.id {
            return orgId
        }

        if let ouId = self.$organizationalUnit.id,
            let ou = try await OrganizationalUnit.find(ouId, on: db)
        {
            return ou.$organization.id
        }

        return nil
    }

    /// Validates that an environment exists in this project
    func hasEnvironment(_ environment: String) -> Bool {
        return environments.contains(environment)
    }

    /// The environment a create lands in: the one it asked for, or this
    /// project's default.
    ///
    /// One copy of "resolve then validate" for every resource that carries an
    /// environment. VM and sandbox create resolved it inline in
    /// `Request.resolveProjectForCreate`; volumes need the same answer (STR-181)
    /// but reach their project through `authorizedProjectForCreate`, which has no
    /// environment of its own, so the step lives here rather than in one of the
    /// two request helpers.
    func resolveEnvironment(_ requested: String?) throws -> String {
        let environment = requested ?? defaultEnvironment
        guard hasEnvironment(environment) else {
            throw Abort(
                .badRequest,
                reason:
                    "Environment '\(environment)' not available in project. Available: \(environments.joined(separator: ", "))"
            )
        }
        return environment
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
            let index = environments.firstIndex(of: environment)
        else {
            return false
        }
        environments.remove(at: index)
        return true
    }
}

// MARK: - Validations

extension Project {
    /// Hard cap on deployment environments per project. A project's
    /// environments are caller-supplied strings that every VM and sandbox in it
    /// is tagged with and that quotas can be scoped per; the list is a
    /// small enumeration, not a data structure to grow.
    static let maxEnvironments = 32

    /// Bounds and structural checks, run by every create and update path
    /// immediately before the save — including the generated OpenAPI service,
    /// which doesn't decode a `ValidatedRequestBody`. This is where the
    /// project's text is held to a ceiling (STR-195).
    ///
    /// It normalizes as well as bounds, but it is deliberately *not* the first
    /// place normalization happens: `ProjectsAPIService` runs the same
    /// `Validate` helpers before its uniqueness query and its
    /// `environments.contains(defaultEnvironment)` guards, because a check that
    /// reads the raw value while the save writes the trimmed one is how
    /// `"Foo "` slips into a scope that already holds `"Foo"`. Trimming is
    /// idempotent, so running it again here costs nothing and keeps any path
    /// that reaches a save without going through that service honest.
    func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
        try Validate.list(environments, "environments", max: Self.maxEnvironments)
        environments = try environments.map { try Validate.name($0, "environments") }
        defaultEnvironment = try Validate.name(defaultEnvironment, "defaultEnvironment")

        // Ensure project belongs to either org or OU, but not both
        if self.$organization.id != nil && self.$organizationalUnit.id != nil {
            throw Abort(.badRequest, reason: "Project cannot belong to both an organization and a folder")
        }

        if self.$organization.id == nil && self.$organizationalUnit.id == nil {
            throw Abort(.badRequest, reason: "Project must belong to either an organization or a folder")
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

// MARK: - Additional DTOs

struct TransferProjectRequest: Content {
    let organizationId: UUID?
    let organizationalUnitId: UUID?
}

struct ProjectPathComponent: Content {
    let id: UUID
    let name: String
    let type: String  // "organization", "organizational_unit", "project"
}

struct ProjectPathResponse: Content {
    let projectId: UUID
    let path: String
    let components: [ProjectPathComponent]
}
