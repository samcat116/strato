import AppTestSupport
import Fluent
import Foundation
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("Add metadata source to VM migration", .serialized)
struct AddMetadataSourceToVMTests {
    @Test("existing rows remain on the complete seed ISO")
    func existingRowsDefaultToISO() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            try await app.db.schema(VM.schema)
                .field("id", .uuid, .identifier(auto: false))
                .field("name", .string, .required)
                .create()
            let sql = try #require(app.db as? any SQLDatabase)
            let vmID = UUID()
            try await sql.raw(
                "INSERT INTO vms (id, name) VALUES (\(bind: vmID), 'existing-vm')"
            ).run()

            try await AddMetadataSourceToVM().prepare(on: app.db)

            let source = try await sql.raw(
                "SELECT metadata_source FROM vms WHERE id = \(bind: vmID)"
            ).first(decodingColumn: "metadata_source", as: String.self)
            #expect(source == "iso")

            await #expect(throws: (any Error).self) {
                try await sql.raw(
                    "UPDATE vms SET metadata_source = 'unknown' WHERE id = \(bind: vmID)"
                ).run()
            }
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
