import ControlPlanePostgres
import Foundation
import Vapor

struct Organization: Content, Equatable, Sendable {
    let id: UUID?
    let name: String
    let description: String
    let createdAt: Date?
    let updatedAt: Date?

    init(
        id: UUID? = UUID(),
        name: String,
        description: String,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(snapshot: OrganizationSnapshot) {
        self.init(
            id: snapshot.id,
            name: snapshot.name,
            description: snapshot.description,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt)
    }

    func requireID() throws -> UUID {
        guard let id else { throw Abort(.internalServerError, reason: "Organization has no identifier") }
        return id
    }

    func save(on db: PostgresStoreContext) async throws {
        _ = try await LegacyOrganizationStore.upsert(self, on: db)
    }

    static func find(_ id: UUID?, on db: PostgresStoreContext) async throws -> Self? {
        try await LegacyOrganizationStore.organization(id: id, on: db)
    }

    static func all(on db: PostgresStoreContext) async throws -> [Self] {
        try await LegacyOrganizationStore.organizations(on: db)
    }

    static func count(on db: PostgresStoreContext) async throws -> Int {
        try await LegacyOrganizationStore.count(on: db)
    }
}

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

// MARK: - DTOs

struct CreateOrganizationRequest: Content, ValidatedRequestBody {
    var name: String
    // Optional: the frontend omits this when the description field is left
    // blank. Decoding a required field here 400s the whole create request.
    let description: String?

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
    }
}

struct UpdateOrganizationRequest: Content, ValidatedRequestBody {
    var name: String?
    let description: String?

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
    }
}

struct OrganizationResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let createdAt: Date?
    let userRole: UUID?

    init(from organization: Organization, userRole: UUID? = nil) {
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
    /// The canonical `iam_roles` id, or nil for bare membership.
    let role: UUID?
    /// The role's human-readable name, or nil for bare membership.
    let roleDisplayName: String?
    let joinedAt: Date?
}

// MARK: - Helper Methods

extension Organization {
    /// Get all projects in this organization (including those in OUs).
    ///
    /// Two flat queries, not a tree walk: a project hangs off exactly one of an
    /// organization or a folder (`Project.validate`), and every folder
    /// denormalizes the organization it belongs to (issue #692).
    func getAllProjects(on db: PostgresStoreContext) async throws -> [Project] {
        guard let organizationID = id else { return [] }
        let folderIDs = try await LegacyOrganizationalUnitStore.organizationalUnits(
            organizationIDs: [organizationID], on: db
        ).compactMap(\.id)
        return try await Project.all(inOrganization: organizationID, folders: folderIDs, on: db)
    }

}

extension OrganizationalUnit {
    /// Get all projects in this OU and its descendants
    func getAllProjects(on db: PostgresStoreContext) async throws -> [Project] {
        let folderIDs = try await selfAndDescendantIDs(on: db)
        guard !folderIDs.isEmpty else { return [] }
        return try await LegacyProjectStore.projects(organizationalUnitIDs: folderIDs, on: db)
    }
}

extension Project {
    /// Every project of an organization, given the ids of its folders: those
    /// hanging directly off the organization plus those inside any folder.
    static func all(inOrganization organizationID: UUID, folders folderIDs: [UUID], on db: PostgresStoreContext) async throws
        -> [Project]
    {
        try await LegacyProjectStore.projects(
            organizationIDs: [organizationID], organizationalUnitIDs: folderIDs, on: db)
    }
}
