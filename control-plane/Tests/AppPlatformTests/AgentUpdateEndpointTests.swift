import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Tests for `POST /api/agents/:agentId/actions/update` — the operator's
/// "update now", which since STR-145 assigns the same declarative field the
/// fleet rollout uses instead of dispatching an imperative command (ADR 0001
/// stage 6). Two halves: the refusals that must trip before anything is
/// assigned (offline agents, pre-v7 wire protocols that ignore the field,
/// missing artifacts, the sandbox re-adoption caveat), and the assignment
/// itself landing on the agent row for sync assembly to pick up.
@Suite("Agent Update Endpoint Tests", .serialized)
final class AgentUpdateEndpointTests {

    private static let target = "1.4.0"
    private static let validDigest = String(repeating: "ab", count: 32)

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
        version: String = "1.0.0",
        wireProtocolVersion: Int = WireProtocol.desiredAgentUpdateMinimumVersion,
        operatingSystem: String? = "linux"
    ) async throws -> Agent {
        let agent = Agent(
            name: "hv-update-\(UUID().uuidString.prefix(8))",
            hostname: "hv.example",
            version: version,
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

    private func reload(_ agent: Agent, on app: Application) async throws -> Agent {
        let row = try await Agent.find(agent.requireID(), on: app.db)
        return try #require(row)
    }

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

    @Test("agents on a pre-v7 wire protocol are refused with the real reason")
    func oldWireProtocolRefused() async throws {
        try await withUpdateTestApp { app, _, org, token in
            // A pre-v7 agent decodes the sync but ignores `desiredAgentUpdate`:
            // assigning it would report an update that converges on nothing.
            let agent = try await self.makeAgent(
                app: app, org: org,
                wireProtocolVersion: WireProtocol.desiredAgentUpdateMinimumVersion - 1)

            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("wire protocol"))
            }
            #expect(try await self.reload(agent, on: app).updateDesiredVersion == nil)
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

    @Test("an explicit artifact with no target version to converge on is refused")
    func explicitArtifactRequiresTargetVersion() async throws {
        try await withUpdateTestApp { app, _, org, token in
            // No STRATO_VERSION/AGENT_TARGET_VERSION in tests, and no
            // targetVersion in the body: there is nothing to measure
            // convergence against, so the assignment could only ever be
            // recorded as failed after its health budget.
            let agent = try await self.makeAgent(app: app, org: org)

            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "artifactUrl": "https://mirror.internal/strato-linux-x86_64.tar.gz",
                    "sha256": Self.validDigest,
                ])
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("targetVersion"))
            }
            #expect(try await self.reload(agent, on: app).updateDesiredVersion == nil)
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

            // No force: the request must clear every gate and land the
            // assignment, proving hosted Firecracker VMs no longer trip one.
            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "artifactUrl": "https://mirror.internal/strato-linux-x86_64.tar.gz",
                    "sha256": Self.validDigest,
                    "targetVersion": Self.target,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
            #expect(try await self.reload(agent, on: app).updateDesiredVersion == Self.target)
        }
    }

    @Test("the assignment lands on the row and rides the agent's next sync")
    func assignmentLandsOnTheRow() async throws {
        try await withUpdateTestApp { app, _, org, token in
            // Online per heartbeat, but no WebSocket is connected in this
            // harness — which no longer matters: the assignment is durable on
            // the row and the agent picks it up on its next sync, so an agent
            // that is mid-reconnect no longer loses the update.
            let agent = try await self.makeAgent(app: app, org: org)

            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "artifactUrl": "https://mirror.internal/strato-linux-x86_64.tar.gz?token=secret",
                    "sha256": Self.validDigest,
                    "targetVersion": Self.target,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                let body = try res.content.decode(AgentController.AgentUpdateResponse.self)
                #expect(body.status == "assigned")
                #expect(body.targetVersion == Self.target)
                // The response goes to any agent#manage holder, so a presigned
                // artifact URL must come back redacted.
                #expect(!body.artifactUrl.contains("secret"))
            }

            let row = try await self.reload(agent, on: app)
            #expect(row.updateDesiredVersion == Self.target)
            #expect(row.updateAssignmentSource == .manual)
            #expect(row.updateAttemptedAt != nil)
            // Manual updates need no auto-update enrollment.
            #expect(!row.autoUpdate)

            // The override is pinned to the row (there is no release to
            // re-resolve it from) and assembly hands it to the agent verbatim.
            let sync = try await app.desiredStateAssembler.assemble(
                agentId: agent.requireID().uuidString)
            let update = try #require(sync.desiredAgentUpdate)
            #expect(update.targetVersion == Self.target)
            #expect(update.artifactURL == "https://mirror.internal/strato-linux-x86_64.tar.gz?token=secret")
            #expect(update.sha256 == Self.validDigest)
            #expect(update.artifactKind == .tarball)
            #expect(update.tarballMember == AgentUpdateArtifacts.defaultTarballMember)
        }
    }

    @Test("an agent already at the target is refused, force or not")
    func alreadyAtTargetRefused() async throws {
        try await withUpdateTestApp { app, _, org, token in
            // Convergence is "the agent re-registered at this version", so an
            // agent already there has nothing to converge on: the assignment
            // would hang until the health budget called it failed. `force` no
            // longer reinstalls.
            let agent = try await self.makeAgent(app: app, org: org, version: "v\(Self.target)")

            struct Body: Content {
                let artifactUrl: String
                let sha256: String
                let targetVersion: String
                let force: Bool
            }
            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    Body(
                        artifactUrl: "https://mirror.internal/strato-linux-x86_64.tar.gz",
                        sha256: Self.validDigest,
                        targetVersion: Self.target,
                        force: true
                    ))
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("already runs"))
            }
            #expect(try await self.reload(agent, on: app).updateDesiredVersion == nil)
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
            #expect(try await self.reload(agent, on: app).updateDesiredVersion == nil)
        }
    }

    @Test("explicit artifact overrides are system-admin only")
    func explicitArtifactRequiresSystemAdmin() async throws {
        try await withUpdateTestApp { app, builder, org, _ in
            // A delegated org admin: their org-admin binding grants
            // agent manage, but explicit artifacts are arbitrary host code and
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
            #expect(try await self.reload(agent, on: app).updateDesiredVersion == nil)
        }
    }

    @Test("an explicit bare-binary artifact is pinned to the row as such")
    func explicitBinaryArtifactAccepted() async throws {
        try await withUpdateTestApp { app, _, org, token in
            // The operator hands a bare executable (artifactKind "binary"):
            // the shape must survive onto the row and out to the sync, since
            // it decides whether the agent extracts a tarball member or
            // installs the download itself.
            let agent = try await self.makeAgent(app: app, org: org)

            struct BinaryBody: Content {
                let artifactUrl: String
                let sha256: String
                let artifactKind: String
                let targetVersion: String
            }
            try await app.test(.POST, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    BinaryBody(
                        artifactUrl: "https://mirror.internal/strato-agent",
                        sha256: Self.validDigest,
                        artifactKind: "binary",
                        targetVersion: Self.target
                    ))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let sync = try await app.desiredStateAssembler.assemble(
                agentId: agent.requireID().uuidString)
            let update = try #require(sync.desiredAgentUpdate)
            #expect(update.artifactKind == .binary)
            #expect(update.tarballMember == nil)
        }
    }
}
