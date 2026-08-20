import ControlPlanePostgres
import Foundation
import Vapor

struct CreateGroupRequest: Content, ValidatedRequestBody {
    var name: String
    let description: String

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
    }
}

struct UpdateGroupRequest: Content, ValidatedRequestBody {
    var name: String?
    let description: String?

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
    }
}

struct GroupResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let organizationId: UUID
    let memberCount: Int?
    let createdAt: Date?

    init(from group: GroupSnapshot, memberCount: Int? = nil) {
        self.id = group.id
        self.name = group.name
        self.description = group.description
        self.organizationId = group.organizationID
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

    init(from member: GroupMemberSnapshot) {
        self.id = member.userID
        self.username = member.username
        self.displayName = member.displayName
        self.email = member.email
        self.joinedAt = member.joinedAt
    }
}

struct AddGroupMemberRequest: Content {
    let userIds: [UUID]
}

struct RemoveGroupMemberRequest: Content {
    let userIds: [UUID]
}
