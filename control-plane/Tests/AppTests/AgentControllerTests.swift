import Fluent
import StratoShared
import Vapor
import VaporTesting
@testable import App
import Testing

@Suite("Agent Controller Tests", .serialized)
struct AgentControllerTests {

    @Test("sanitizedHost passes through a bare host")
    func bareHost() {
        #expect(AgentController.sanitizedHost("cp.example.com") == "cp.example.com")
    }

    @Test("sanitizedHost keeps a port")
    func hostWithPort() {
        #expect(AgentController.sanitizedHost("localhost:8080") == "localhost:8080")
    }

    @Test("sanitizedHost strips a scheme")
    func stripsScheme() {
        #expect(AgentController.sanitizedHost("https://cp.example.com") == "cp.example.com")
    }

    @Test("sanitizedHost strips a trailing path and slash")
    func stripsPath() {
        #expect(AgentController.sanitizedHost("https://cp.example.com/") == "cp.example.com")
        #expect(AgentController.sanitizedHost("cp.example.com/strato") == "cp.example.com")
    }

    @Test("sanitizedHost trims whitespace")
    func trimsWhitespace() {
        #expect(AgentController.sanitizedHost(" cp.example.com \n") == "cp.example.com")
    }

    @Test("Agent GET endpoints derive heartbeat status without persisting it")
    func readsDoNotPersistHeartbeatStatus() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "agent-reader",
                email: "agent-reader@example.com",
                displayName: "Agent Reader",
                isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app.db)
            let organization = try await builder.createOrganization(name: "Agent Read Org")

            let freshOffline = try await makeAgent(
                name: "fresh-offline",
                status: .offline,
                lastHeartbeat: Date(),
                organization: organization,
                on: app.db)
            let staleOnline = try await makeAgent(
                name: "stale-online",
                status: .online,
                lastHeartbeat: Date().addingTimeInterval(-120),
                organization: organization,
                on: app.db)

            try await app.test(.GET, "/api/agents") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let responses = try res.content.decode([AgentResponse].self)
                let statusByID = Dictionary(uniqueKeysWithValues: responses.map { ($0.id, $0.status) })
                #expect(statusByID[freshOffline.id!] == .online)
                #expect(statusByID[staleOnline.id!] == .offline)
            }

            try await app.test(.GET, "/api/agents/\(freshOffline.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(AgentResponse.self)
                #expect(response.status == .online)
            }

            let persistedFresh = try #require(try await Agent.find(freshOffline.id, on: app.db))
            let persistedStale = try #require(try await Agent.find(staleOnline.id, on: app.db))
            #expect(persistedFresh.status == .offline)
            #expect(persistedStale.status == .online)
        }
    }

    private func makeAgent(
        name: String,
        status: AgentStatus,
        lastHeartbeat: Date,
        organization: Organization,
        on db: Database
    ) async throws -> Agent {
        let agent = Agent(
            name: name,
            hostname: "\(name).example",
            version: "1.0.0",
            capabilities: ["qemu"],
            status: status,
            resources: AgentResources(
                totalCPU: 8,
                availableCPU: 8,
                totalMemory: 16_000_000_000,
                availableMemory: 16_000_000_000,
                totalDisk: 100_000_000_000,
                availableDisk: 100_000_000_000),
            lastHeartbeat: lastHeartbeat)
        agent.organizationScope = .organization(try organization.requireID())
        try await agent.save(on: db)
        return agent
    }
}
