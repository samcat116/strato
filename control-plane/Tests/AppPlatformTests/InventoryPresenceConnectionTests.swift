import AppTestSupport
import Fluent
import FluentPostgresDriver
import NIOPosix
import StratoShared
import Testing
import Vapor

@testable import App

@Suite("Inventory presence connection reuse", .serialized, .postgresFixture)
struct InventoryPresenceConnectionTests {
    @Test("Reports refresh presence with one connection and do not revive a revoked agent", arguments: [false, true])
    func refreshWithOneConnection(revoked: Bool) async throws {
        let database = try await PostgresTestDatabases.shared.createDatabaseForTest()
        // A single loop makes an accidental app.db checkout deterministic,
        // rather than occasionally borrowing the other loop's connection.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let app = try await Application.make(.testing, .shared(group))
        app.databases.use(
            .postgres(
                configuration: PostgresTestDatabases.configuration(database: database),
                maxConnectionsPerEventLoop: 1, connectionPoolTimeout: .milliseconds(250)),
            as: .psql)
        app.storage[TestDatabaseNameKey.self] = database
        do {
            try await configure(app)
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Inventory presence")
            let agent = try await builder.createAgent(
                named: "single-connection", organizationScope: .organization(try org.requireID()))
            let key = agent.identity.key
            try await app.agentService.beginObservedInventorySession(for: key)
            if revoked {
                agent.administrativelyOffline = true
                try await agent.save(on: app.db)
            }
            let resources = AgentResources(
                totalCPU: 8, availableCPU: 6, totalMemory: 8 << 30, availableMemory: 6 << 30,
                totalDisk: 100 << 30, availableDisk: 90 << 30)
            let report = ObservedStateReport(agentId: try agent.requireID().uuidString, vms: [], resources: resources)
            await app.agentService.applyObservedStateReport(try MessageEnvelope(message: report), fromAgentKey: key)

            let refreshed = await app.agentService.presenceRefreshedAt[key]
            #expect((refreshed != nil) == !revoked)
            let persisted = try #require(try await Agent.find(agent.id, on: app.db))
            #expect(persisted.administrativelyOffline == revoked)
            if !revoked { #expect(persisted.availableCPU == resources.availableCPU) }
            // A subsequent fenced operation must also be able to use the only
            // connection: the report must release its connection and lock.
            let agentID = try agent.requireID()
            try await InventorySessionFence.withLock(agentID: agentID, on: app.db, logger: app.logger) {
                connection in
                let session = try await InventorySessionFence.current(agentID: agentID, on: connection)
                #expect(session != nil)
            }
        } catch {
            try? await app.shutdownForTesting()
            try? await group.shutdownGracefully()
            throw error
        }
        try await app.shutdownForTesting()
        try await group.shutdownGracefully()
    }
}
