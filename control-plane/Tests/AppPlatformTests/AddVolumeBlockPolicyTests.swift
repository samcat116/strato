import AppTestSupport
import Fluent
import Foundation
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("Add volume block policy migration", .serialized)
struct AddVolumeBlockPolicyTests {
    @Test("existing volumes remain conservative and invalid modes are rejected")
    func backfillsConservativePolicy() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            try await app.db.schema(Volume.schema)
                .field("id", .uuid, .identifier(auto: false))
                .field("name", .string, .required)
                .create()
            let sql = try #require(app.db as? any SQLDatabase)
            let volumeID = UUID()
            try await sql.raw(
                "INSERT INTO volumes (id, name) VALUES (\(bind: volumeID), 'legacy-volume')"
            ).run()

            let migration = AddVolumeBlockPolicy()
            try await migration.prepare(on: app.db)
            // The compatibility migration is intentionally safe to retry on a
            // database whose fresh baseline already contains both columns.
            try await migration.prepare(on: app.db)

            let mode = try await sql.raw(
                "SELECT block_mode FROM volumes WHERE id = \(bind: volumeID)"
            ).first(decodingColumn: "block_mode", as: String.self)
            #expect(mode == "conservative")

            let policyIsNull = try await sql.raw(
                "SELECT applied_block_policy IS NULL AS value FROM volumes WHERE id = \(bind: volumeID)"
            ).first(decodingColumn: "value", as: Bool.self)
            #expect(policyIsNull == true)

            try await sql.raw(
                "UPDATE volumes SET block_mode = 'direct' WHERE id = \(bind: volumeID)"
            ).run()
            await #expect(throws: (any Error).self) {
                try await sql.raw(
                    "UPDATE volumes SET block_mode = 'unsafe' WHERE id = \(bind: volumeID)"
                ).run()
            }
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
