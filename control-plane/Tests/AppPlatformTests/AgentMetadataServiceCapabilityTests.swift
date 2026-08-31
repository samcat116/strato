import AppTestSupport
import Fluent
import Foundation
import SQLKit
import StratoShared
import Testing
import Vapor

@testable import App

@Suite("Agent metadata-service capability", .serialized)
struct AgentMetadataServiceCapabilityTests {
    private let resources = AgentResources(
        totalCPU: 4, availableCPU: 4,
        totalMemory: 8 * 1024 * 1024 * 1024,
        availableMemory: 8 * 1024 * 1024 * 1024,
        totalDisk: 100 * 1024 * 1024 * 1024,
        availableDisk: 100 * 1024 * 1024 * 1024)

    @Test("Registration mapping is absent-means-false")
    func registrationMappingFailsClosed() {
        let implicit = Agent.from(
            registration: AgentRegisterMessage(
                agentId: "implicit", hostname: "implicit", version: "1", resources: resources),
            name: "implicit", siteID: UUID())
        #expect(!implicit.metadataServiceCapable)

        let capable = Agent.from(
            registration: AgentRegisterMessage(
                agentId: "capable", hostname: "capable", version: "1", resources: resources,
                metadataServiceCapable: true),
            name: "capable", siteID: UUID())
        #expect(capable.metadataServiceCapable)
    }

    @Test("Migration keeps existing agents ineligible until registration")
    func migrationDefaultsExistingRowsToFalse() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            try await app.db.schema(Agent.schema)
                .field("id", .uuid, .identifier(auto: false))
                .field("name", .string, .required)
                .create()
            let sql = try #require(app.db as? any SQLDatabase)
            let agentID = UUID()
            try await sql.raw(
                "INSERT INTO agents (id, name) VALUES (\(bind: agentID), 'existing-agent')"
            ).run()

            try await AddAgentMetadataServiceCapability().prepare(on: app.db)

            let capable = try await sql.raw(
                "SELECT metadata_service_capable FROM agents WHERE id = \(bind: agentID)"
            ).first(decodingColumn: "metadata_service_capable", as: Bool.self)
            #expect(capable == false)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
