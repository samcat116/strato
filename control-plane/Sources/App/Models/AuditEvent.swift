import Fluent
import Vapor

/// A durable audit-trail record (issue #39). Rows are written by the
/// `database` audit backend; other backends (log, Loki, webhook) ship the same
/// data externally and don't touch this table.
///
/// `user_id` and `organization_id` deliberately have no foreign keys: audit
/// events must outlive the user or organization they describe.
final class AuditEvent: Model, @unchecked Sendable {
    static let schema = "audit_events"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "event_type")
    var eventType: String

    @OptionalField(key: "user_id")
    var userID: UUID?

    /// Username snapshot at event time, so the trail stays readable after the
    /// user row is deleted or renamed.
    @OptionalField(key: "username")
    var username: String?

    @OptionalField(key: "api_key_id")
    var apiKeyID: UUID?

    @OptionalField(key: "organization_id")
    var organizationID: UUID?

    @OptionalField(key: "method")
    var method: String?

    @OptionalField(key: "path")
    var path: String?

    @OptionalField(key: "status")
    var status: Int?

    @OptionalField(key: "resource_type")
    var resourceType: String?

    @OptionalField(key: "resource_id")
    var resourceID: String?

    @OptionalField(key: "action")
    var action: String?

    @OptionalField(key: "source_ip")
    var sourceIP: String?

    /// True when the request was served through the system-admin permission
    /// bypass — these are the "first-class admin audit events" from issue #39.
    @Field(key: "admin_bypass")
    var adminBypass: Bool

    @OptionalField(key: "metadata")
    var metadataJSON: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(from record: AuditRecord) {
        self.eventType = record.eventType
        self.userID = record.userID
        self.username = record.username
        self.apiKeyID = record.apiKeyID
        self.organizationID = record.organizationID
        self.method = record.method
        self.path = record.path
        self.status = record.status
        self.resourceType = record.resourceType
        self.resourceID = record.resourceID
        self.action = record.action
        self.sourceIP = record.sourceIP
        self.adminBypass = record.adminBypass
        if let metadata = record.metadata,
            let data = try? JSONEncoder().encode(metadata)
        {
            self.metadataJSON = String(data: data, encoding: .utf8)
        }
    }

    var metadata: [String: String]? {
        guard let metadataJSON, let data = metadataJSON.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }
}

extension AuditEvent: Content {}
