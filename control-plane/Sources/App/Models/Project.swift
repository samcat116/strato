import ControlPlanePostgres
import Foundation
import Vapor

struct Project: Content, Equatable, Sendable {
    static let schema = "projects"

    let id: UUID?
    let name: String
    let description: String
    let organizationID: UUID?
    let organizationalUnitID: UUID?
    let path: String
    let defaultEnvironment: String
    let environments: [String]
    let createdAt: Date?
    let updatedAt: Date?

    init(
        id: UUID? = UUID(),
        name: String,
        description: String,
        organizationID: UUID? = nil,
        organizationalUnitID: UUID? = nil,
        path: String,
        defaultEnvironment: String = "development",
        environments: [String] = ["development", "staging", "production"],
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.organizationID = organizationID
        self.organizationalUnitID = organizationalUnitID
        self.path = path
        self.defaultEnvironment = defaultEnvironment
        self.environments = environments
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(snapshot: ProjectSnapshot) {
        self.init(
            id: snapshot.id, name: snapshot.name, description: snapshot.description,
            organizationID: snapshot.organizationID,
            organizationalUnitID: snapshot.organizationalUnitID,
            path: snapshot.path, defaultEnvironment: snapshot.defaultEnvironment,
            environments: snapshot.environments,
            createdAt: snapshot.createdAt, updatedAt: snapshot.updatedAt)
    }

    func requireID() throws -> UUID {
        guard let id else { throw Abort(.internalServerError, reason: "Project has no identifier") }
        return id
    }

    func save(on db: PostgresStoreContext) async throws {
        _ = try await LegacyProjectStore.upsert(self, on: db)
    }

    func delete(on db: PostgresStoreContext) async throws {
        guard let id else { return }
        _ = try await LegacyProjectStore.delete(id: id, on: db)
    }

    static func find(_ id: UUID?, on db: PostgresStoreContext) async throws -> Self? {
        try await LegacyProjectStore.project(id: id, on: db)
    }

    static func all(on db: PostgresStoreContext) async throws -> [Self] {
        try await LegacyProjectStore.projects(on: db)
    }

    static func count(name: String? = nil, on db: PostgresStoreContext) async throws -> Int {
        try await LegacyProjectStore.count(name: name, on: db)
    }

    func replacingPath(_ path: String) -> Self {
        replacing(path: path)
    }

    func replacingScope(organizationID: UUID?, organizationalUnitID: UUID?) -> Self {
        Self(
            id: id, name: name, description: description,
            organizationID: organizationID, organizationalUnitID: organizationalUnitID,
            path: path, defaultEnvironment: defaultEnvironment,
            environments: environments, createdAt: createdAt, updatedAt: updatedAt)
    }

    func replacing(
        name: String? = nil,
        description: String? = nil,
        organizationID: UUID?? = nil,
        organizationalUnitID: UUID?? = nil,
        path: String? = nil,
        defaultEnvironment: String? = nil,
        environments: [String]? = nil
    ) -> Self {
        Self(
            id: id, name: name ?? self.name, description: description ?? self.description,
            organizationID: organizationID ?? self.organizationID,
            organizationalUnitID: organizationalUnitID ?? self.organizationalUnitID,
            path: path ?? self.path,
            defaultEnvironment: defaultEnvironment ?? self.defaultEnvironment,
            environments: environments ?? self.environments,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}

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
            organizationId: self.organizationID,
            organizationalUnitId: self.organizationalUnitID,
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
    func buildPath(on db: PostgresStoreContext) async throws -> String {
        var parentPath = ""

        // If project belongs to an OU, get the OU's path
        if let ouId = self.organizationalUnitID {
            if let ou = try await OrganizationalUnit.find(ouId, on: db) {
                parentPath = ou.path
            }
        } else if let orgId = self.organizationID {
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
    func getRootOrganizationId(on db: PostgresStoreContext) async throws -> UUID? {
        if let orgId = self.organizationID {
            return orgId
        }

        if let ouId = self.organizationalUnitID,
            let ou = try await OrganizationalUnit.find(ouId, on: db)
        {
            return ou.organizationID
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
    func addingEnvironment(_ environment: String) -> Self {
        guard !environments.contains(environment) else { return self }
        return replacing(environments: environments + [environment])
    }

    /// Removes an environment from the project (if not the default)
    func removingEnvironment(_ environment: String) -> Self? {
        guard environment != defaultEnvironment,
            let index = environments.firstIndex(of: environment)
        else {
            return nil
        }
        var remaining = environments
        remaining.remove(at: index)
        return replacing(environments: remaining)
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
        _ = try Validate.name(name)
        try Validate.text(description)
        try Validate.list(environments, "environments", max: Self.maxEnvironments)
        _ = try environments.map { try Validate.name($0, "environments") }
        _ = try Validate.name(defaultEnvironment, "defaultEnvironment")

        // Ensure project belongs to either org or OU, but not both
        if self.organizationID != nil && self.organizationalUnitID != nil {
            throw Abort(.badRequest, reason: "Project cannot belong to both an organization and a folder")
        }

        if self.organizationID == nil && self.organizationalUnitID == nil {
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
        self.organizationId = project.organizationID
        self.organizationalUnitId = project.organizationalUnitID
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
