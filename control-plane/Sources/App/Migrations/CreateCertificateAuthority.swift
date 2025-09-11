import Fluent

struct CreateCertificateAuthority: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("certificate_authorities")
            .id()
            .field("name", .string, .required)
            .field("trust_domain", .string, .required)
            .field("certificate_pem", .string, .required)
            .field("private_key_pem", .string, .required)
            .field("serial_counter", .int64, .required)
            .field("status", .string, .required)
            .field("valid_from", .datetime)
            .field("valid_to", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "name")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("certificate_authorities").delete()
    }
}