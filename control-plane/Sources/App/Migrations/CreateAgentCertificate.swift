import Fluent

struct CreateAgentCertificate: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agent_certificates")
            .id()
            .field("agent_id", .string, .required)
            .field("spiffe_uri", .string, .required)
            .field("certificate_pem", .string, .required)
            .field("serial_number", .string, .required)
            .field("status", .string, .required)
            .field("ca_id", .uuid, .required, .references("certificate_authorities", "id"))
            .field("issued_at", .datetime)
            .field("expires_at", .datetime)
            .field("revoked_at", .datetime)
            .field("revocation_reason", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "serial_number")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agent_certificates").delete()
    }
}