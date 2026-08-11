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
            let secondVMID = UUID()
            try await sql.raw(
                "INSERT INTO vms (id, name) VALUES (\(bind: vmID), 'existing-vm'), (\(bind: secondVMID), 'existing-vm-2')"
            ).run()

            try await AddMetadataSourceToVM().prepare(on: app.db)

            let source = try await sql.raw(
                "SELECT metadata_source FROM vms WHERE id = \(bind: vmID)"
            ).first(decodingColumn: "metadata_source", as: String.self)
            #expect(source == "iso")

            let firstToken = try await sql.raw(
                "SELECT metadata_seed_token FROM vms WHERE id = \(bind: vmID)"
            ).first(decodingColumn: "metadata_seed_token", as: UUID.self)
            let secondToken = try await sql.raw(
                "SELECT metadata_seed_token FROM vms WHERE id = \(bind: secondVMID)"
            ).first(decodingColumn: "metadata_seed_token", as: UUID.self)
            #expect(firstToken != nil)
            #expect(secondToken != nil)
            #expect(firstToken != secondToken)

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
