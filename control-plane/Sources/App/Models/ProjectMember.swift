import Fluent
import Vapor
import Foundation

/// The roles a user or group can hold on a project. Values match the SpiceDB
/// `project` relations for user grants (`admin`/`member`/`viewer`); group grants map
/// these to the `group_admin`/`group_member`/`group_viewer` relations.
enum ProjectRole: String, Content, CaseIterable {
    case admin
    case member
    case viewer

    /// The corresponding SpiceDB group-relation for group grants.
    var groupRelation: GroupProjectRole {
        switch self {
        case .admin: return .admin
        case .member: return .member
        case .viewer: return .viewer
        }
    }
}

/// A user's direct role on a specific project.
///
/// SpiceDB is the authorization source of truth; this table is a relational mirror
/// (written alongside the SpiceDB tuple) so the members list can be rendered with a
/// fast, joinable query instead of paginating SpiceDB LookupSubjects. Same pattern as
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

/// A group's role grant on a specific project (relational mirror of the SpiceDB
/// `project#group_<role>@group` tuple).
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
