import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Declarative agent auto-update (issue #434): the health-gated rollout
/// sweep, the desired-state assembly that carries the assignment, the
/// observed-report path that lands agent-reported blockers/failures on the
/// row, and the PATCH toggle.
@Suite("Agent Auto-Update Rollout Tests", .serialized)
final class AgentAutoUpdateTests {

    private static let target = "1.4.0"
    private static let validDigest = String(repeating: "cd", count: 32)

    private static let stubArtifact = ResolvedAgentArtifact(
        url: "https://releases.example/v1.4.0/strato-linux-x86_64.tar.gz",
        sha256: validDigest,
        kind: .tarball,
        tarballMember: "strato-agent"
    )

    private func withAutoUpdateApp(
        _ test: (Application, TestDataBuilder, Organization, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            // Test processes have no STRATO_VERSION/AGENT_TARGET_VERSION, so
            // the compiled-in target is nil; inject one, plus an artifact
            // resolver that never leaves the process.
            await app.agentService.setAutoUpdateTargetForTesting(Self.target)
            await app.agentService.setAgentArtifactResolverForTesting { _, _, _ in Self.stubArtifact }

            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "autoupdateadmin",
                email: "autoupdate@example.com",
                displayName: "Auto Update Admin",
                isSystemAdmin: true
            )
            let org = try await builder.createOrganization(name: "Auto Update Org")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            let token = try await admin.generateAPIKey(on: app.db)

            try await test(app, builder, org, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// The sweep lock's TTL outlives back-to-back test sweeps; give each
    /// sweep call a fresh in-memory coordination store so none is skipped.
    private func sweep(_ app: Application) async {
        app.coordination = CoordinationService(store: InMemoryCoordinationStore(), logger: app.logger)
        await app.agentService.sweepAgentAutoUpdates()
    }

    @discardableResult
    private func makeAgent(
        app: Application,
        org: Organization,
        name: String,
        version: String = "1.0.0",
        autoUpdate: Bool = true,
        online: Bool = true,
        wireProtocolVersion: Int = WireProtocol.desiredAgentUpdateMinimumVersion,
        operatingSystem: String? = "linux"
    ) async throws -> Agent {
        let agent = Agent(
            name: name,
            hostname: "\(name).example",
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
        agent.autoUpdate = autoUpdate
        agent.organizationScope = .organization(try org.requireID())
        try await agent.save(on: app.db)
        return agent
    }

    private func reload(_ agent: Agent, on app: Application) async throws -> Agent {
        let row = try await Agent.find(agent.requireID(), on: app.db)
        return try #require(row)
    }

    // MARK: - Rollout sweep

    @Test("the sweep assigns exactly one agent at a time, in name order")
    func assignsOneAgentAtATime() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            let second = try await self.makeAgent(app: app, org: org, name: "bb-agent")

            await self.sweep(app)

            let firstRow = try await self.reload(first, on: app)
            let secondRow = try await self.reload(second, on: app)
            #expect(firstRow.updateDesiredVersion == Self.target)
            #expect(firstRow.updateAttemptedAt != nil)
            #expect(secondRow.updateDesiredVersion == nil)

            // A second pass while the first agent is still converging must
            // not advance.
            await self.sweep(app)
            let secondRowAgain = try await self.reload(second, on: app)
            #expect(secondRowAgain.updateDesiredVersion == nil)
        }
    }

    @Test("the rollout advances only after the assigned agent re-registers at the target")
    func advancesOnConvergence() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            let second = try await self.makeAgent(app: app, org: org, name: "bb-agent")

            await self.sweep(app)

            // The agent restarts into the new build and re-registers with a
            // v-prefixed tag — canonical comparison must count that as
            // converged.
            let firstRow = try await self.reload(first, on: app)
            firstRow.version = "v\(Self.target)"
            try await firstRow.save(on: app.db)

            await self.sweep(app)

            let firstAfter = try await self.reload(first, on: app)
            let secondAfter = try await self.reload(second, on: app)
            #expect(firstAfter.updateDesiredVersion == nil)
            #expect(firstAfter.updateAttemptedAt == nil)
            #expect(secondAfter.updateDesiredVersion == Self.target)
        }
    }

    @Test("silence past the health budget records a failure and halts the rollout")
    func silenceHaltsRollout() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            let second = try await self.makeAgent(app: app, org: org, name: "bb-agent")

            await self.sweep(app)

            // Backdate the assignment past the budget with no blocked reason
            // reported: the agent went silent.
            let firstRow = try await self.reload(first, on: app)
            firstRow.updateAttemptedAt = Date(
                timeIntervalSinceNow: -(AgentService.autoUpdateHealthBudgetSeconds + 60))
            try await firstRow.save(on: app.db)

            await self.sweep(app)

            let firstAfter = try await self.reload(first, on: app)
            #expect(firstAfter.updateFailureReason?.contains("did not re-register") == true)
            // The assignment survives for the operator (and for the agent to
            // converge on if it comes back), but the rollout is halted.
            #expect(firstAfter.updateDesiredVersion == Self.target)

            await self.sweep(app)
            let secondAfter = try await self.reload(second, on: app)
            #expect(secondAfter.updateDesiredVersion == nil)
        }
    }

    @Test("a blocked agent past the budget is parked and the rollout advances without it")
    func blockedAgentIsParked() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            let second = try await self.makeAgent(app: app, org: org, name: "bb-agent")

            await self.sweep(app)

            let firstRow = try await self.reload(first, on: app)
            firstRow.updateBlockedReason = "2 reconcile work item(s) are in flight"
            firstRow.updateAttemptedAt = Date(
                timeIntervalSinceNow: -(AgentService.autoUpdateHealthBudgetSeconds + 60))
            try await firstRow.save(on: app.db)

            await self.sweep(app)

            // Parked: the assignment stays (level-triggered — the agent
            // converges whenever its blocker clears) but no longer gates
            // advancement.
            let firstAfter = try await self.reload(first, on: app)
            #expect(firstAfter.updateDesiredVersion == Self.target)
            #expect(firstAfter.updateAttemptedAt == nil)
            #expect(firstAfter.updateFailureReason == nil)

            await self.sweep(app)
            let secondAfter = try await self.reload(second, on: app)
            #expect(secondAfter.updateDesiredVersion == Self.target)
        }
    }

    @Test("an assignment for a superseded target is reset, failures included")
    func staleTargetIsReset() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            agent.updateDesiredVersion = "1.3.0"
            agent.updateAttemptedAt = Date(timeIntervalSinceNow: -3600)
            agent.updateFailureReason = "did not re-register at 1.3.0"
            try await agent.save(on: app.db)

            await self.sweep(app)

            // The old target's halt must not block the new target: the same
            // pass resets the stale assignment and re-assigns the current one.
            let after = try await self.reload(agent, on: app)
            #expect(after.updateDesiredVersion == Self.target)
            #expect(after.updateFailureReason == nil)
            #expect(after.updateAttemptedAt != nil)
        }
    }

    @Test("offline, pre-v7, unenrolled, and already-converged agents are never assigned")
    func ineligibleAgentsAreSkipped() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let offline = try await self.makeAgent(app: app, org: org, name: "aa-offline", online: false)
            let oldWire = try await self.makeAgent(
                app: app, org: org, name: "bb-oldwire",
                wireProtocolVersion: WireProtocol.desiredAgentUpdateMinimumVersion - 1)
            let unenrolled = try await self.makeAgent(app: app, org: org, name: "cc-unenrolled", autoUpdate: false)
            // v-prefixed tag vs bare target: canonical comparison, no update.
            let converged = try await self.makeAgent(app: app, org: org, name: "dd-converged", version: "v1.4.0")

            await self.sweep(app)

            for agent in [offline, oldWire, unenrolled, converged] {
                let row = try await self.reload(agent, on: app)
                #expect(row.updateDesiredVersion == nil, "\(row.name) must not be assigned")
            }
        }
    }

    @Test("an unresolvable artifact defers assignment instead of burning the agent's budget")
    func unresolvableArtifactDefersAssignment() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            await app.agentService.setAgentArtifactResolverForTesting { _, _, _ in
                throw Abort(.badGateway, reason: "release host down")
            }
            let agent = try await self.makeAgent(app: app, org: org, name: "aa-agent")

            await self.sweep(app)

            let row = try await self.reload(agent, on: app)
            #expect(row.updateDesiredVersion == nil)
            #expect(row.updateFailureReason == nil)
        }
    }

    // MARK: - Sync assembly

    @Test("the sync carries the assigned update with the freshly resolved artifact")
    func syncCarriesAssignedUpdate() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            agent.updateDesiredVersion = Self.target
            agent.updateAttemptedAt = Date()
            try await agent.save(on: app.db)

            let sync = try await app.agentService.assembleDesiredState(
                agentId: agent.requireID().uuidString)

            let update = try #require(sync.desiredAgentUpdate)
            #expect(update.targetVersion == Self.target)
            #expect(update.artifactURL == Self.stubArtifact.url)
            #expect(update.sha256 == Self.validDigest)
            #expect(update.artifactKind == .tarball)
            #expect(update.tarballMember == "strato-agent")
        }
    }

    @Test("the sync omits the update for unassigned, converged, and pre-v7 agents")
    func syncOmitsUpdateWhenNotActionable() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let unassigned = try await self.makeAgent(app: app, org: org, name: "aa-unassigned")

            let converged = try await self.makeAgent(app: app, org: org, name: "bb-converged", version: "v1.4.0")
            converged.updateDesiredVersion = Self.target
            try await converged.save(on: app.db)

            let oldWire = try await self.makeAgent(
                app: app, org: org, name: "cc-oldwire",
                wireProtocolVersion: WireProtocol.desiredAgentUpdateMinimumVersion - 1)
            oldWire.updateDesiredVersion = Self.target
            try await oldWire.save(on: app.db)

            for agent in [unassigned, converged, oldWire] {
                let sync = try await app.agentService.assembleDesiredState(
                    agentId: agent.requireID().uuidString)
                #expect(sync.desiredAgentUpdate == nil, "\(agent.name) must not be sent an update")
            }
        }
    }

    @Test("an artifact-resolution outage omits the update but not the sync")
    func assemblySurvivesResolutionOutage() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            await app.agentService.setAgentArtifactResolverForTesting { _, _, _ in
                throw Abort(.badGateway, reason: "release host down")
            }
            let agent = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            agent.updateDesiredVersion = Self.target
            try await agent.save(on: app.db)

            let sync = try await app.agentService.assembleDesiredState(
                agentId: agent.requireID().uuidString)
            #expect(sync.desiredAgentUpdate == nil)
        }
    }

    // MARK: - Observed update status

    private func report(
        from agent: Agent, status: ObservedAgentUpdateStatus?
    ) throws -> MessageEnvelope {
        try MessageEnvelope(
            message: ObservedStateReport(
                agentId: try agent.requireID().uuidString,
                vms: [],
                resources: AgentResources(
                    totalCPU: 8, availableCPU: 8,
                    totalMemory: 16_000_000_000, availableMemory: 16_000_000_000,
                    totalDisk: 100_000_000_000, availableDisk: 100_000_000_000
                ),
                agentUpdateStatus: status
            ))
    }

    @Test("a blocked report lands on the row and a clean report clears it")
    func blockedReportRoundTrip() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            agent.updateDesiredVersion = Self.target
            agent.updateAttemptedAt = Date()
            try await agent.save(on: app.db)

            let blocked = ObservedAgentUpdateStatus(
                targetVersion: Self.target,
                disposition: ObservedAgentUpdateStatus.dispositionBlocked,
                reason: "1 reconcile work item(s) are in flight"
            )
            await app.agentService.applyObservedStateReport(
                try self.report(from: agent, status: blocked), fromAgentKey: agent.identity.key)
            var row = try await self.reload(agent, on: app)
            #expect(row.updateBlockedReason == "1 reconcile work item(s) are in flight")
            #expect(row.updateFailureReason == nil)

            await app.agentService.applyObservedStateReport(
                try self.report(from: agent, status: nil), fromAgentKey: agent.identity.key)
            row = try await self.reload(agent, on: app)
            #expect(row.updateBlockedReason == nil)
        }
    }

    @Test("a failed report records the terminal failure that halts the rollout")
    func failedReportHalts() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            first.updateDesiredVersion = Self.target
            first.updateAttemptedAt = Date()
            try await first.save(on: app.db)
            let second = try await self.makeAgent(app: app, org: org, name: "bb-agent")

            let failed = ObservedAgentUpdateStatus(
                targetVersion: Self.target,
                disposition: ObservedAgentUpdateStatus.dispositionFailed,
                reason: "artifact checksum mismatch"
            )
            await app.agentService.applyObservedStateReport(
                try self.report(from: first, status: failed), fromAgentKey: first.identity.key)

            let firstRow = try await self.reload(first, on: app)
            #expect(firstRow.updateFailureReason == "artifact checksum mismatch")

            await self.sweep(app)
            let secondRow = try await self.reload(second, on: app)
            #expect(secondRow.updateDesiredVersion == nil)
        }
    }

    @Test("a report about a superseded target is ignored")
    func staleReportIgnored() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            agent.updateDesiredVersion = Self.target
            agent.updateAttemptedAt = Date()
            try await agent.save(on: app.db)

            let stale = ObservedAgentUpdateStatus(
                targetVersion: "1.3.0",
                disposition: ObservedAgentUpdateStatus.dispositionFailed,
                reason: "old news"
            )
            await app.agentService.applyObservedStateReport(
                try self.report(from: agent, status: stale), fromAgentKey: agent.identity.key)

            let row = try await self.reload(agent, on: app)
            #expect(row.updateFailureReason == nil)
            #expect(row.updateBlockedReason == nil)
        }
    }

    // MARK: - PATCH toggle

    @Test("PATCH enrolls an agent and withdrawal clears the rollout state")
    func patchTogglesEnrollment() async throws {
        try await withAutoUpdateApp { app, _, org, token in
            let agent = try await self.makeAgent(app: app, org: org, name: "aa-agent", autoUpdate: false)

            try await app.test(.PATCH, "/api/agents/\(agent.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["autoUpdate": true])
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(AgentResponse.self)
                #expect(body.autoUpdate)
            }

            // Simulate an in-flight assignment, then withdraw.
            let row = try await self.reload(agent, on: app)
            row.updateDesiredVersion = Self.target
            row.updateAttemptedAt = Date()
            row.updateBlockedReason = "blocked"
            row.updateFailureReason = "failed"
            try await row.save(on: app.db)

            try await app.test(.PATCH, "/api/agents/\(agent.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["autoUpdate": false])
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(AgentResponse.self)
                #expect(!body.autoUpdate)
                #expect(body.updateDesiredVersion == nil)
                #expect(body.updateBlockedReason == nil)
                #expect(body.updateFailureReason == nil)
            }

            let after = try await self.reload(agent, on: app)
            #expect(!after.autoUpdate)
            #expect(after.updateDesiredVersion == nil)
            #expect(after.updateAttemptedAt == nil)
        }
    }

    @Test("re-enrolling clears a previous failure so the rollout can retry")
    func reenrollClearsFailure() async throws {
        try await withAutoUpdateApp { app, _, org, token in
            let agent = try await self.makeAgent(app: app, org: org, name: "aa-agent", autoUpdate: false)
            agent.updateFailureReason = "did not re-register"
            try await agent.save(on: app.db)

            try await app.test(.PATCH, "/api/agents/\(agent.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["autoUpdate": true])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let after = try await self.reload(agent, on: app)
            #expect(after.autoUpdate)
            #expect(after.updateFailureReason == nil)
        }
    }
}
