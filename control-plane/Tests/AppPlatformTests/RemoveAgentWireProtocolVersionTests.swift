import AppTestSupport
import Fluent
import Foundation
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("Remove agent wire protocol version migration", .serialized)
struct RemoveAgentWireProtocolVersionTests {
    @Test("is a no-op on the fresh schema baseline")
    func freshSchemaAlreadyOmitsColumn() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            try await CurrentSchemaBaseline().prepare(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            #expect(try await columnCount(on: sql) == 0)

            let migration = RemoveAgentWireProtocolVersion()
            try await migration.prepare(on: app.db)
            try await migration.prepare(on: app.db)
            #expect(try await columnCount(on: sql) == 0)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("drops only the redundant agent column")
    func dropsWireProtocolVersionColumn() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            try await app.db.schema(Agent.schema)
                .field("id", .uuid, .identifier(auto: false))
                .field("name", .string, .required)
                .field("wire_protocol_version", .int)
                .create()

            let sql = try #require(app.db as? any SQLDatabase)
            let agentID = UUID()
            try await sql.raw(
                "INSERT INTO agents (id, name, wire_protocol_version) VALUES (\(bind: agentID), 'agent-1', 47)"
            ).run()

            let migration = RemoveAgentWireProtocolVersion()
            try await migration.prepare(on: app.db)
            try await migration.prepare(on: app.db)

            let retainedName = try await sql.raw(
                "SELECT name FROM agents WHERE id = \(bind: agentID)"
            ).first(decodingColumn: "name", as: String.self)
            #expect(retainedName == "agent-1")
            #expect(try await columnCount(on: sql) == 0)

            try await migration.revert(on: app.db)
            try await migration.revert(on: app.db)
            #expect(try await columnCount(on: sql) == 1)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func columnCount(on sql: any SQLDatabase) async throws -> Int {
        try #require(
            try await sql.raw(
                """
                SELECT count(*)::int AS count
                FROM information_schema.columns
                WHERE table_schema = current_schema()
                  AND table_name = 'agents'
                  AND column_name = 'wire_protocol_version'
                """
            ).first(decodingColumn: "count", as: Int.self)
        )
    }
}
