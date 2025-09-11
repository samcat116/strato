import Fluent

struct CreateCertificateAuditEvent: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("certificate_audit_events")
            .id()
            .field("event_type", .string, .required)
            .field("agent_id", .string)
            .field("certificate_id", .uuid)
            .field("spiffe_uri", .string)
            .field("client_ip", .string)
            .field("details", .string, .required)
            .field("timestamp", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("certificate_audit_events").delete()
    }
}