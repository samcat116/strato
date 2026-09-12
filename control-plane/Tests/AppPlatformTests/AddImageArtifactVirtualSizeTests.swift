import AppTestSupport
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("Add image artifact virtual size migration", .serialized)
struct AddImageArtifactVirtualSizeTests {
    @Test("Existing raw images are backfilled while sparse image sizes remain unknown")
    func backfillsOnlyAuthoritativeLegacySizes() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw(
                """
                CREATE TABLE image_artifacts (
                    id uuid PRIMARY KEY,
                    format text,
                    size bigint NOT NULL
                )
                """
            ).run()
            let rawID = UUID()
            let qcowID = UUID()
            try await sql.raw(
                """
                INSERT INTO image_artifacts (id, format, size)
                VALUES
                    (\(bind: rawID), 'raw', 42),
                    (\(bind: qcowID), 'qcow2', 7)
                """
            ).run()

            let migration = AddImageArtifactVirtualSize()
            try await migration.prepare(on: app.db)

            struct Row: Decodable {
                let id: UUID
                let virtual_size: Int64?
            }
            let rows = try await sql.raw(
                "SELECT id, virtual_size FROM image_artifacts ORDER BY id"
            ).all(decoding: Row.self)
            #expect(rows.count == 2)
            #expect(rows.first { $0.id == rawID }?.virtual_size == 42)
            #expect(rows.first { $0.id == qcowID }?.virtual_size == nil)

            try await migration.revert(on: app.db)
            let remaining = try await sql.raw(
                """
                SELECT count(*)::bigint AS count
                FROM information_schema.columns
                WHERE table_schema = current_schema()
                  AND table_name = 'image_artifacts'
                  AND column_name = 'virtual_size'
                """
            ).first(decodingColumn: "count", as: Int64.self)
            #expect(remaining == 0)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
