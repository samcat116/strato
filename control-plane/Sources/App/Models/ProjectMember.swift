import Fluent
import Vapor
import Foundation

/// The roles a user or group can hold on a project (`admin`/`member`/`viewer`).
enum ProjectRole: String, Content, CaseIterable {
    case admin
    case member
    case viewer
}

/// A user's direct role on a specific project.
///
/// The Cedar evaluator's `role_bindings` are the authorization source of truth;
/// this table is a relational mirror (written alongside the binding) so the
/// members list can be rendered with a fast, joinable query. Same pattern as
/// `UserOrganization`.
final class ProjectMember: Model, @unchecked Sendable {
    static let schema = "project_members"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "project_id")
    var project: Project

    @Parent(key: "user_id")
    var user: User

    @Field(key: "role")
    var role: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, projectID: UUID, userID: UUID, role: String) {
        self.id = id
        self.$project.id = projectID
        self.$user.id = userID
        self.role = role
    }
}

extension ProjectMember: Content {}

/// A group's role grant on a specific project (mirrored by a group-principal
/// role binding on the project node).
final class ProjectGroupGrant: Model, @unchecked Sendable {
    static let schema = "project_group_grants"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "project_id")
    var project: Project

    @Parent(key: "group_id")
    var group: Group

    @Field(key: "role")
    var role: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, projectID: UUID, groupID: UUID, role: String) {
        self.id = id
        self.$project.id = projectID
        self.$group.id = groupID
        self.role = role
    }
}

extension ProjectGroupGrant: Content {}
