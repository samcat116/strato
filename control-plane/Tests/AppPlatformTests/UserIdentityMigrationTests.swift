import AppTestSupport
import Fluent
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("User identity database backstop", .serialized, .postgresFixture)
struct UserIdentityMigrationTests {
    @Test("Length checks are idempotent and reject writes bypassing the model")
    func databaseBackstop() async throws {
        try await withTestApp { app in
            let migration = AddUserIdentityLengthConstraints()
            try await migration.prepare(on: app.db)
            try await migration.prepare(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            let user = User(username: "valid", email: "valid@example.com", displayName: "Valid")
            try await user.save(on: app.db)
            for (field, value) in [
                ("username", String(repeating: "a", count: 65)),
                ("email", String(repeating: "a", count: 255)),
                ("display_name", String(repeating: "e\u{301}", count: 65)),
            ] {
                await #expect(throws: (any Error).self) {
                    try await sql.raw(
                        "UPDATE users SET \(unsafeRaw: field) = \(bind: value) WHERE id = \(bind: user.id!)"
                    ).run()
                }
            }
        }
    }

    @Test("Upgrade refuses invalid historical rows without changing them")
    func invalidExistingRows() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            try await CurrentSchemaBaseline().prepare(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw(
                """
                INSERT INTO users (id, username, email, display_name, is_system_admin, source,
                    scim_provisioned, scim_active, session_epoch)
                VALUES (\(bind: UUID()), '', '', '', false, 'oidc', false, true, 0)
                """
            ).run()
            await #expect(throws: Abort.self) {
                try await AddUserIdentityLengthConstraints().prepare(on: app.db)
            }
            let checks = try await sql.raw("SELECT conname FROM pg_constraint WHERE conname LIKE 'ck_users_%_length'")
                .all()
            #expect(checks.isEmpty)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
