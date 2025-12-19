import Fluent
import Vapor
import Foundation

final class Group: Model, @unchecked Sendable {
    static let schema = "groups"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "description")
    var description: String

    @Parent(key: "organization_id")
    var organization: Organization

    // SCIM provisioning field
    @Field(key: "scim_provisioned")
    var scimProvisioned: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    // Relationships
    @Siblings(through: UserGroup.self, from: \.$group, to: \.$user)
    var users: [User]

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        description: String,
        organizationID: UUID,
        scimProvisioned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.$organization.id = organizationID
        self.scimProvisioned = scimProvisioned
    }
}

extension Group: Content {}

extension Group {
    struct Public: Content {
        let id: UUID?
        let name: String
        let description: String
        let organizationId: UUID
        let createdAt: Date?
    }

    func asPublic() -> Public {
        return Public(
            id: self.id,
            name: self.name,
            description: self.description,
            organizationId: self.$organization.id,
            createdAt: self.createdAt
        )
    }
}

// MARK: - User-Group Relationship (Many-to-Many)

final class UserGroup: Model, @unchecked Sendable {
    static let schema = "user_groups"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Parent(key: "group_id")
    var group: Group

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userID: UUID,
        groupID: UUID
    ) {
        self.id = id
        self.$user.id = userID
        self.$group.id = groupID
    }
}

extension UserGroup: Content {}

// MARK: - DTOs

struct CreateGroupRequest: Content {
    let name: String
    let description: String
}

struct UpdateGroupRequest: Content {
    let name: String?
    let description: String?
}

struct GroupResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let organizationId: UUID
    let memberCount: Int?
    let createdAt: Date?

    init(from group: Group, memberCount: Int? = nil) {
        self.id = group.id
        self.name = group.name
        self.description = group.description
        self.organizationId = group.$organization.id
        self.memberCount = memberCount
        self.createdAt = group.createdAt
    }
}

struct GroupMemberResponse: Content {
    let id: UUID?
    let username: String
    let displayName: String
    let email: String
    let joinedAt: Date?

    init(from user: User, joinedAt: Date? = nil) {
        self.id = user.id
        self.username = user.username
        self.displayName = user.displayName
        self.email = user.email
        self.joinedAt = joinedAt
    }
}

struct AddGroupMemberRequest: Content {
    let userIds: [UUID]
}

struct RemoveGroupMemberRequest: Content {
    let userIds: [UUID]
}

// MARK: - Helper Methods

extension Group {
    /// Get member count for this group
    func getMemberCount(on db: Database) async throws -> Int {
        return try await Int(self.$users.query(on: db).count())
    }

    /// Check if a user is a member of this group
    func hasMember(_ userID: UUID, on db: Database) async throws -> Bool {
        let membership = try await UserGroup.query(on: db)
            .filter(\.$group.$id, .equal, self.id!)
            .filter(\.$user.$id, .equal, userID)
            .first()

        return membership != nil
    }

    /// Add a user to this group
    func addMember(_ userID: UUID, on db: Database) async throws {
        // Check if user is already a member
        let exists = try await hasMember(userID, on: db)
        if exists {
            return // Already a member
        }

        let membership = UserGroup(userID: userID, groupID: self.id!)
        try await membership.save(on: db)
    }

    /// Remove a user from this group
    func removeMember(_ userID: UUID, on db: Database) async throws {
        try await UserGroup.query(on: db)
            .filter(\.$group.$id, .equal, self.id!)
            .filter(\.$user.$id, .equal, userID)
            .delete()
    }

    /// Get all members of this group with their join dates
    func getMembersWithJoinDates(on db: Database) async throws -> [GroupMemberResponse] {
        let memberships = try await UserGroup.query(on: db)
            .filter(\.$group.$id, .equal, self.id!)
            .with(\.$user)
            .all()

        return memberships.map { membership in
            GroupMemberResponse(
                from: membership.user,
                joinedAt: membership.createdAt
            )
        }
    }
}
