import Fluent
import Vapor
import Foundation

/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
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
    var groups: [Group]

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

/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class UserOrganization: Model, @unchecked Sendable {
    static let schema = "user_organizations"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Parent(key: "organization_id")
    var organization: Organization

    /// The canonical role mirrored for this membership, or nil for bare
    /// membership. Authorization always reads the corresponding RoleBinding.
    @OptionalField(key: "role_id")
    var roleID: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        organizationID: UUID,
        roleID: UUID? = nil
    ) {
        self.id = id
        self.$user.id = userID
        self.$organization.id = organizationID
        self.roleID = roleID
    }
}

extension UserOrganization: Content {}

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
    func getAllProjects(on db: Database) async throws -> [Project] {
        guard let organizationID = id else { return [] }
        let folderIDs = try await OrganizationalUnit.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .all(\.$id)
            .compactMap { $0 }
        return try await Project.all(inOrganization: organizationID, folders: folderIDs, on: db)
    }

}

extension OrganizationalUnit {
    /// Get all projects in this OU and its descendants
    func getAllProjects(on db: Database) async throws -> [Project] {
        let folderIDs = try await selfAndDescendantIDs(on: db)
        guard !folderIDs.isEmpty else { return [] }
        return try await Project.query(on: db)
            .filter(\.$organizationalUnit.$id ~~ folderIDs)
            .all()
    }
}

extension Project {
    /// Every project of an organization, given the ids of its folders: those
    /// hanging directly off the organization plus those inside any folder.
    static func all(inOrganization organizationID: UUID, folders folderIDs: [UUID], on db: Database) async throws
        -> [Project]
    {
        try await Project.query(on: db)
            .group(.or) { anyProject in
                anyProject.filter(\.$organization.$id == organizationID)
                if !folderIDs.isEmpty {
                    anyProject.filter(\.$organizationalUnit.$id ~~ folderIDs)
                }
            }
            .all()
    }
}
