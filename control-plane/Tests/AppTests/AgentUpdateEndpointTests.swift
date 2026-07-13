import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Tests for `POST /api/agents/:agentId/actions/update` — the refusal paths
/// that must trip *before* anything is dispatched to the agent: offline
/// agents, pre-v6 wire protocols (which cannot decode the command and would
/// only ever time out), unresolvable artifacts, and the sandbox re-adoption
/// caveat. The dispatch itself is exercised up to the socket lookup (no agent
/// is connected, so an update that clears every gate reports the agent as
/// unreachable).
@Suite("Agent Update Endpoint Tests", .serialized)
final class AgentUpdateEndpointTests {

    private func withUpdateTestApp(
        _ test: (Application, TestDataBuilder, Organization, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            // System admin: agent update authorization itself is covered by
            // the same requireAgentPermission path as force-offline; these
            // tests target the update-specific gating.
            let admin = try await builder.createUser(
                username: "updateadmin",
                email: "update@example.com",
                displayName: "Update Admin",
                isSystemAdmin: true
            )
            let org = try await builder.createOrganization(name: "Update Org")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            let token = try await admin.generateAPIKey(on: app.db)

            try await test(app, builder, org, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    private func makeAgent(
        app: Application,
        org: Organization,
        online: Bool = true,
        wireProtocolVersion: Int = WireProtocol.agentUpdateMinimumVersion,
        operatingSystem: String? = "linux"
    ) async throws -> Agent {
        let agent = Agent(
            name: "hv-update-\(UUID().uuidString.prefix(8))",
            hostname: "hv.example",
            version: "1.0.0",
            capabilities: ["qemu"],
            status: online ? .online : .offline,
            resources: AgentResources(
                totalCPU: 8, availableCPU: 8,
                totalMemory: 16_000_000_000, availableMemory: 16_000_000_000,
                totalDisk: 100_000_000_000, availableDisk: 100_000_000_000
            ),
            architecture: .x86_64,
            lastHeartbeat: online ? Date() : Date(timeIntervalSinceNow: -3600)
        )
        agent.wireProtocolVersion = wireProtocolVersion
        agent.operatingSystem = operatingSystem
        agent.organizationScope = .organization(try org.requireID())
        try await agent.save(on: app.db)
        return agent
    }

    private static let validDigest = String(repeating: "ab", count: 32)

    @Test("offline agents are refused")
    func offlineAgentRefused() async throws {
        try await withUpdateTestApp { app, _, org, token in
            let agent = try await self.makeAgent(app: app, org: org, online: false)

            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("offline"))
            }
        }
    }

    @Test("agents on a pre-v6 wire protocol are refused with the real reason")
    func oldWireProtocolRefused() async throws {
        try await withUpdateTestApp { app, _, org, token in
            let agent = try await self.makeAgent(app: app, org: org, wireProtocolVersion: 5)

            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("wire protocol"))
            }
        }
    }

    @Test("without a configured target version, an explicit artifact is required")
    func devBuildRequiresExplicitArtifact() async throws {
        try await withUpdateTestApp { app, _, org, token in
            // Test processes run without STRATO_VERSION/AGENT_TARGET_VERSION,
            // so AgentVersionTarget.version is nil — exactly the dev case.
            let agent = try await self.makeAgent(app: app, org: org)

            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("target version"))
            }
        }
    }

    @Test("an explicit artifact URL without a sha256 is refused")
    func explicitArtifactRequiresDigest() async throws {
        try await withUpdateTestApp { app, _, org, token in
            let agent = try await self.makeAgent(app: app, org: org)

            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "artifactUrl": "https://mirror.internal/strato-linux-x86_64.tar.gz"
                ])
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("sha256"))
            }
        }
    }

    @Test("hosted Firecracker VMs do not require force (re-adopted since #433)")
    func firecrackerVMsDoNotRequireForce() async throws {
        try await withUpdateTestApp { app, builder, org, token in
            let agent = try await self.makeAgent(app: app, org: org)

            let project = try await builder.createProject(
                name: "FC Project", description: "project with a Firecracker VM", organization: org)
            let vm = try await builder.createVM(name: "fc-vm", project: project)
            vm.hypervisorId = agent.id!.uuidString
            vm.hypervisorType = .firecracker
            try await vm.save(on: app.db)

            // No force: the request must clear every pre-dispatch gate and
            // fail only at the send itself (no agent socket in this harness),
            // proving hosted Firecracker VMs no longer trip the guard.
            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "artifactUrl": "https://mirror.internal/strato-linux-x86_64.tar.gz",
                    "sha256": Self.validDigest,
                ])
            } afterResponse: { res in
                #expect(res.status == .badGateway)
            }
        }
    }

    @Test("a dispatchable update against a disconnected agent reports it unreachable")
    func disconnectedAgentReportedUnreachable() async throws {
        try await withUpdateTestApp { app, _, org, token in
            // Online per heartbeat, but no WebSocket is actually connected in
            // this harness: every pre-dispatch gate passes and the send itself
            // fails, mapping to a 502 rather than a success.
            let agent = try await self.makeAgent(app: app, org: org)

            struct ForceBody: Content {
                let artifactUrl: String
                let sha256: String
                let force: Bool
            }
            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ForceBody(
                        artifactUrl: "https://mirror.internal/strato-linux-x86_64.tar.gz",
                        sha256: Self.validDigest,
                        force: true
                    ))
            } afterResponse: { res in
                #expect(res.status == .badGateway)
            }
        }
    }

    @Test("hosted sandboxes require force (runtime does not yet re-adopt them)")
    func sandboxesRequireForce() async throws {
        try await withUpdateTestApp { app, builder, org, token in
            let agent = try await self.makeAgent(app: app, org: org)

            let project = try await builder.createProject(
                name: "Sandbox Project", description: "project with a sandbox", organization: org)
            let sandbox = Sandbox(
                name: "sb-1",
                projectID: try project.requireID(),
                environment: "development",
                image: "docker.io/library/alpine:3",
                cpus: 1,
                memory: 512_000_000
            )
            sandbox.hypervisorId = agent.id!.uuidString
            try await sandbox.save(on: app.db)

            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "artifactUrl": "https://mirror.internal/strato-linux-x86_64.tar.gz",
                    "sha256": Self.validDigest,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("sandbox"))
            }
        }
    }

    @Test("explicit artifact overrides are system-admin only")
    func explicitArtifactRequiresSystemAdmin() async throws {
        try await withUpdateTestApp { app, builder, org, _ in
            // A delegated org admin: SpiceDB grants agent#manage (mocked
            // all-allow), but explicit artifacts are arbitrary host code and
            // must stay system-admin only. The same request without the
            // override (exercised elsewhere) is allowed for this user.
            let delegated = try await builder.createUser(
                username: "orgadmin",
                email: "orgadmin@example.com",
                displayName: "Org Admin",
                isSystemAdmin: false
            )
            try await builder.addUserToOrganization(user: delegated, organization: org, role: "admin")
            let delegatedToken = try await delegated.generateAPIKey(on: app.db)
            app.spicedbMockAllows = true

            let agent = try await self.makeAgent(app: app, org: org)

            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: delegatedToken)
                try req.content.encode([
                    "artifactUrl": "https://attacker.example/strato-agent",
                    "sha256": Self.validDigest,
                ])
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("system admin"))
            }
        }
    }

    @Test("an explicit bare-binary artifact passes every gate and reaches dispatch")
    func explicitBinaryArtifactAccepted() async throws {
        try await withUpdateTestApp { app, _, org, token in
            // The operator hands a bare executable (artifactKind "binary"):
            // the request must decode and clear all pre-dispatch gates — the
            // 502 proves it reached the send (no agent socket is connected
            // here), not a 400 from the body or a kind-related refusal.
            let agent = try await self.makeAgent(app: app, org: org)

            struct BinaryBody: Content {
                let artifactUrl: String
                let sha256: String
                let artifactKind: String
                let force: Bool
            }
            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    BinaryBody(
                        artifactUrl: "https://mirror.internal/strato-agent",
                        sha256: Self.validDigest,
                        artifactKind: "binary",
                        force: true
                    ))
            } afterResponse: { res in
                #expect(res.status == .badGateway)
            }
        }
    }
}
