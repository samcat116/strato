import AppTestSupport
import Fluent
import SQLKit
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

@Suite("Agent administrative revocation", .serialized, .postgresFixture)
struct AgentRevocationTests {
    @Test("The administrative state migration defaults existing rows active and reverts")
    func migrationPreservesExistingAgents() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("CREATE TABLE agents (id uuid PRIMARY KEY)").run()
            let id = UUID()
            try await sql.raw("INSERT INTO agents (id) VALUES (\(bind: id))").run()
            let migration = AddAgentAdministrativeOffline()
            try await migration.prepare(on: app.db)
            let held = try await sql.raw("SELECT administratively_offline FROM agents WHERE id = \(bind: id)")
                .first(decodingColumn: "administratively_offline", as: Bool.self)
            #expect(held == false)
            try await migration.revert(on: app.db)
            let count = try await sql.raw("SELECT count(*)::bigint AS count FROM agents")
                .first(decodingColumn: "count", as: Int64.self)
            #expect(count == 1)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("Three heartbeat intervals cannot undo an administrative offline hold")
    func heartbeatCannotResurrect() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Hold Org")
            let agent = try await builder.createAgent(
                named: "held-node", status: .online,
                organizationScope: .organization(try org.requireID()))
            // Retain a pre-action snapshot to exercise the save race too.
            let stale = try #require(try await Agent.find(agent.id, on: app.db))
            try await Agent.query(on: app.db).filter(\.$id == agent.id!)
                .set(\.$administrativelyOffline, to: true).set(\.$status, to: .offline).update()
            stale.status = .online
            await #expect(throws: Abort.self) { try await app.agentService.saveActiveAgent(stale, on: app.db) }
            for interval in 1...3 {
                let row = try #require(try await Agent.find(agent.id, on: app.db))
                let resources = AgentResources(
                    totalCPU: 8, availableCPU: 8,
                    totalMemory: 1024, availableMemory: 1024, totalDisk: 1024, availableDisk: 1024)
                let changed = await app.agentService.applyPeriodicAgentState(
                    resources, dependencyObservations: nil, to: row,
                    at: .testing(Date().addingTimeInterval(Double(interval * 20))))
                try await app.agentService.updateAgentHeartbeat(
                    AgentHeartbeatMessage(agentId: try row.requireID().uuidString, resources: resources),
                    fromAgentKey: row.identity.key)
                #expect(try await Agent.find(row.id, on: app.db)?.status == .offline)
                #expect(!changed)
                #expect(row.status == .offline)
                await app.agentService.refreshAgentPresenceIfNeeded(agentKey: row.identity.key, force: true)
                #expect(await app.coordination.isAgentPresent(agentKey: row.identity.key) == false)
                await #expect(throws: Abort.self) {
                    try await WorkloadRegistry.requireAgentRegistration(identity: row.identity, on: app.db)
                }
            }
        }
    }

    @Test("Force-offline and resume require agent management and resume does not assert liveness")
    func resumeAuthorization() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Resume Org")
            let agent = try await builder.createAgent(
                named: "resume-node", lastHeartbeat: Date(), organizationScope: .organization(try org.requireID()))
            let admin = try await builder.createUser(
                username: "resume-admin", email: "resume-admin@example.test", isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app.db)
            let id = try agent.requireID()
            try await app.test(.POST, "/api/agents/\(id)/actions/force-offline") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            let held = try #require(try await Agent.find(id, on: app.db))
            #expect(held.administrativelyOffline)
            #expect(!held.isOnline(at: .testing(Date())))
            #expect(held.statusBasedOnHeartbeat(at: .testing(Date())) == .offline)

            let viewer = try await builder.createUser(
                username: "resume-viewer", email: "resume-viewer@example.test", isSystemAdmin: false)
            let viewerToken = try await viewer.generateAPIKey(on: app.db)
            try await app.test(.POST, "/api/agents/\(id)/actions/resume") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: viewerToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            #expect(try await Agent.find(id, on: app.db)?.administrativelyOffline == true)
            try await app.test(.POST, "/api/agents/\(id)/actions/resume") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            let resumed = try #require(try await Agent.find(id, on: app.db))
            #expect(!resumed.administrativelyOffline)
            #expect(resumed.status == .offline)
            #expect(!resumed.isOnline(at: .testing(Date())))
            #expect(resumed.statusBasedOnHeartbeat(at: .testing(Date())) == .offline)
            try await WorkloadRegistry.requireAgentRegistration(identity: resumed.identity, on: app.db)
        }
    }

    @Test("Missing rows do not prevent identity-keyed claim cleanup")
    func deletedRowClaimsAreCleared() async throws {
        try await withTestApp { app in
            let identity = AgentIdentity(trustDomain: "strato.local", name: "already-deleted")
            await app.coordination.recordAgentPresence(agentKey: identity.key)
            await app.replicaBridge.recordRoute(agentKey: identity.key)
            try await app.agentService.forceUnregisterAgent(identity)
            #expect(await app.coordination.isAgentPresent(agentKey: identity.key) == false)
            #expect(await app.coordination.agentRoute(agentKey: identity.key) == nil)
        }
    }
}
