import AppTestSupport
import Fluent
import Foundation
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("Add mutable metadata to VM migration", .serialized)
struct AddMutableMetadataToVMTests {
    @Test("existing SSH keys are preserved and new metadata defaults empty")
    func existingRowsAreBackfilled() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            try await app.db.schema(VM.schema)
                .field("id", .uuid, .identifier(auto: false))
                .field("name", .string, .required)
                .field("ssh_public_key", .string)
                .create()
            let sql = try #require(app.db as? any SQLDatabase)
            let legacyID = UUID()
            let emptyID = UUID()
            let legacyKey =
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f legacy@test"
            try await sql.raw(
                """
                INSERT INTO vms (id, name, ssh_public_key)
                VALUES (\(bind: legacyID), 'legacy', \(bind: legacyKey)),
                       (\(bind: emptyID), 'empty', NULL)
                """
            ).run()

            try await AddMutableMetadataToVM().prepare(on: app.db)

            let keys = try await sql.raw(
                "SELECT ssh_authorized_keys FROM vms WHERE id = \(bind: legacyID)"
            ).first(decodingColumn: "ssh_authorized_keys", as: [String].self)
            #expect(keys == [legacyKey])

            let emptyKeys = try await sql.raw(
                "SELECT ssh_authorized_keys FROM vms WHERE id = \(bind: emptyID)"
            ).first(decodingColumn: "ssh_authorized_keys", as: [String].self)
            #expect(emptyKeys == [])

            let tags = try await sql.raw(
                "SELECT tags::text AS tags_text FROM vms WHERE id = \(bind: legacyID)"
            ).first(decodingColumn: "tags_text", as: String.self)
            #expect(tags == "{}")
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
