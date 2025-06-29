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
    var role: String // "admin" or "member"

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
    let description: String
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
    let role: String
    let joinedAt: Date?
}
