import AppTestSupport
import SQLKit
import StratoShared
import Testing
import Vapor

@testable import App

@Suite("Agent protocol registration ownership", .serialized, .postgresFixture)
struct AgentProtocolSessionTests {
    @Test("Only the current registration can advertise protocol support")
    func sessionReplacement() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw(
                """
                CREATE TABLE agents (
                    id uuid PRIMARY KEY, inventory_session_id uuid,
                    administratively_offline boolean NOT NULL DEFAULT FALSE
                )
                """
            ).run()
            let migration = AddAgentProtocolSupport()
            try await migration.prepare(on: app.db)
            let id = UUID()
            let first = UUID()
            try await sql.raw(
                "INSERT INTO agents (id, inventory_session_id) VALUES (\(bind: id), \(bind: first))"
            ).run()
            await #expect(throws: Abort.self) {
                try await AgentProtocolSession.load(agentID: id, sessionID: first, on: app.db)
            }
            var offer = AgentProtocolCompatibility.localOffer
            offer.capabilities = ["future-feature.v1"]
            try await AgentProtocolSession.persist(offer, agentID: id, sessionID: first, on: app.db)
            let accepted = try await AgentProtocolSession.load(agentID: id, sessionID: first, on: app.db)
            #expect(accepted.id == first)
            #expect(accepted.offer.capabilities == ["future-feature.v1"])
            #expect(accepted.agreement.capabilities.isEmpty)
            let newerReplica = try await AgentProtocolSession.load(
                agentID: id, sessionID: first, localOffer: offer, on: app.db)
            #expect(newerReplica.agreement.capabilities.isEmpty)

            let second = UUID()
            try await InventorySessionFence.replace(second, agentID: id, on: app.db)
            try await AgentProtocolSession.persist(
                AgentProtocolCompatibility.localOffer, agentID: id, sessionID: second, on: app.db)
            await #expect(throws: Abort.self) {
                try await AgentProtocolSession.persist(offer, agentID: id, sessionID: first, on: app.db)
            }
            await #expect(throws: Abort.self) {
                try await AgentProtocolSession.load(agentID: id, sessionID: first, on: app.db)
            }
            let current = try await AgentProtocolSession.load(agentID: id, sessionID: second, on: app.db)
            #expect(current.offer.capabilities.isEmpty)
            try await sql.raw("UPDATE agents SET administratively_offline = TRUE WHERE id = \(bind: id)").run()
            await #expect(throws: Abort.self) {
                try await AgentProtocolSession.load(agentID: id, sessionID: second, on: app.db)
            }
            try await migration.revert(on: app.db)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
