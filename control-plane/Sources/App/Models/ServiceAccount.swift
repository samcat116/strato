import Fluent
import Foundation
import Vapor

/// A machine principal owned by a project (issue #491).
///
/// A service account is the durable identity that SPIFFE workloads
/// authenticate *as*: `workload_registrations` rows map SPIFFE IDs to it, and
/// role bindings name it with `principal_type = service_account`. It is also
/// a resource in the IAM tree (`IAMNodeType.serviceAccount`, parent: its
/// project), so access to the account itself — including the
/// `serviceaccount:impersonate` permission — is governed by ordinary bindings
/// and guardrails.
final class ServiceAccount: Model, Content, @unchecked Sendable {
    static let schema = "service_accounts"

    @ID(key: .id)
    var id: UUID?

    /// Unique within the project.
    @Field(key: "name")
    var name: String

    @Field(key: "description")
    var accountDescription: String

    @Parent(key: "project_id")
    var project: Project

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, name: String, description: String = "", projectID: UUID) {
        self.id = id
        self.name = name
        self.accountDescription = description
        self.$project.id = projectID
    }
}
