import Fluent
import StratoShared
import Synchronization
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Declarative agent auto-update (issue #434): the health-gated rollout
/// sweep, the desired-state assembly that carries the assignment, the
/// observed-report path that lands agent-reported blockers/failures on the
/// row, and the PATCH toggle.
@Suite("Agent Auto-Update Rollout Tests", .serialized, .postgresFixture)
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

            // Test processes have no STRATO_VERSION/AGENT_TARGET_VERSION, so
            // the compiled-in target is nil; inject one, plus an artifact
            // resolver that never leaves the process.
            await app.agentMaintenance.setAutoUpdateTargetForTesting(Self.target)
            app.agentArtifactResolver = AgentArtifactResolver { _, _, _ in Self.stubArtifact }

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

    private actor SweepClock {
        let evaluation: ClusterInstant
        let assignment: ClusterInstant
        var reads = 0

        init(evaluation: ClusterInstant, assignment: ClusterInstant) {
            self.evaluation = evaluation
            self.assignment = assignment
        }

        func read() -> ClusterInstant {
            defer { reads += 1 }
            return reads == 0 ? evaluation : assignment
        }
    }

    /// The sweep lock's TTL outlives back-to-back test sweeps; give each
    /// sweep call a fresh in-memory coordination store so none is skipped.
    private func sweep(
        _ app: Application,
        at instant: ClusterInstant = .testing(Date()),
        assignmentAt assignmentInstant: ClusterInstant? = nil
    ) async {
        app.coordination = CoordinationService(store: InMemoryCoordinationStore(), logger: app.logger)
        let clock = SweepClock(evaluation: instant, assignment: assignmentInstant ?? instant)
        await app.agentMaintenance.sweepAgentAutoUpdates(
            at: instant,
            currentInstant: { _ in await clock.read() })
    }

    @discardableResult
    private func makeAgent(
        app: Application,
        org: Organization,
        name: String,
        version: String = "1.0.0",
        autoUpdate: Bool = true,
        online: Bool = true,
        operatingSystem: String? = "linux"
    ) async throws -> Agent {
        let agent = try await TestDataBuilder(db: app.db).createAgent(
            named: name,
            hostname: "\(name).example",
            version: version,
            status: online ? .online : .offline,
            resources: AgentResources(
                totalCPU: 8, availableCPU: 8,
                totalMemory: 16_000_000_000, availableMemory: 16_000_000_000,
                totalDisk: 100_000_000_000, availableDisk: 100_000_000_000
            ),
            architecture: .x86_64,
            lastHeartbeat: online ? Date() : Date(timeIntervalSinceNow: -3600),
            organizationScope: .organization(try org.requireID()))
        agent.operatingSystem = operatingSystem
        agent.autoUpdate = autoUpdate
        try await agent.save(on: app.db)
        return agent
    }

    private func reload(_ agent: Agent, on app: Application) async throws -> Agent {
        let row = try await Agent.find(agent.requireID(), on: app.db)
        return try #require(row)
    }

    /// Model the target registration plus a later clean inventory/health report.
    private func targetHealth(_ agent: Agent, at date: Date, register: Bool = false) {
        if register { agent.updateTargetRegisteredAt = date }
        agent.lastHeartbeat = date
        agent.dependencyObservationsReceivedAt = date
        agent.updateInventoryReceivedAt = date
    }

    private func verifyTarget(_ agent: Agent, on app: Application) async throws {
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 1)
        self.targetHealth(agent, at: start, register: true)
        try await agent.save(on: app.db)
        await self.sweep(app, at: .testing(start))
        let row = try await self.reload(agent, on: app)
        let end = start.addingTimeInterval(AgentMaintenanceLoop.autoUpdateVerificationSeconds)
        self.targetHealth(row, at: end)
        try await row.save(on: app.db)
        await self.sweep(app, at: .testing(end), assignmentAt: .testing(Date()))
    }

    // MARK: - Rollout sweep

    @Test(
        "assignment respects changes during artifact resolution",
        arguments: ["manual", "withdraw", "offline", "updated", "platform", "removed"])
    func assignmentRace(change: String) async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "audit-agent")
            let id = try agent.requireID()
            app.agentArtifactResolver = AgentArtifactResolver { _, _, _ in
                let current = try #require(try await Agent.find(id, on: app.db))
                switch change {
                case "manual":
                    current.assignUpdate(version: "operator-target", source: .manual, at: .testing(Date()))
                case "withdraw": current.autoUpdate = false
                case "updated": current.version = Self.target
                case "platform": current.operatingSystem = "macos"
                case "removed":
                    try await current.delete(on: app.db)
                    return Self.stubArtifact
                default: current.administrativelyOffline = true
                }
                try await current.save(on: app.db)
                return Self.stubArtifact
            }
            await self.sweep(app)
            if change == "removed" {
                #expect(try await Agent.find(id, on: app.db) == nil)
            } else {
                let row = try await self.reload(agent, on: app)
                #expect(row.updateDesiredVersion == (change == "manual" ? "operator-target" : nil))
            }
        }
    }

    @Test("the sweep judges heartbeat freshness with the cluster clock")
    func heartbeatFreshnessUsesClusterClock() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let instant = ClusterInstant.testing(Date(timeIntervalSince1970: 1_000))
            let agent = try await self.makeAgent(
                app: app, org: org, name: "clock-agent")
            agent.lastHeartbeat = instant.date.addingTimeInterval(-1)
            try await agent.save(on: app.db)

            await self.sweep(app, at: instant)

            let stored = try await self.reload(agent, on: app)
            #expect(stored.updateDesiredVersion == Self.target)
            #expect(stored.updateAttemptedAt == instant.date)
        }
    }

    @Test("a rollout assignment starts from a fresh database instant")
    func assignmentUsesFreshDatabaseInstant() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let assignmentInstant = try await ClusterClock.read(on: app.db)
            let tickInstant = ClusterInstant.testing(
                assignmentInstant.date.addingTimeInterval(-300))
            let agent = try await self.makeAgent(
                app: app, org: org, name: "fresh-assignment-agent")
            agent.lastHeartbeat = assignmentInstant.date.addingTimeInterval(-1)
            try await agent.save(on: app.db)

            await self.sweep(
                app, at: tickInstant, assignmentAt: assignmentInstant)

            let stored = try await self.reload(agent, on: app)
            #expect(stored.updateDesiredVersion == Self.target)
            #expect(stored.updateAttemptedAt == assignmentInstant.date)
        }
    }

    @Test("delayed ticks accept newer reports while genuinely future receipts fail", arguments: [false, true])
    func delayedTickWithNewReport(futureDated: Bool) async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            let second = try await self.makeAgent(app: app, org: org, name: "bb-agent")
            let reportInstant = try await ClusterClock.read(on: app.db)
            let start = reportInstant.date.addingTimeInterval(-61)
            first.assignUpdate(version: Self.target, source: .rollout, at: .testing(start.addingTimeInterval(-1)))
            first.version = Self.target
            first.updateTargetRegisteredAt = start
            first.updateVerificationStartedAt = start
            self.targetHealth(first, at: reportInstant.date.addingTimeInterval(futureDated ? 300 : 0))
            try await first.save(on: app.db)

            // The tick predates this report, as when previous awaited sweeps
            // delay update classification. The production clock must be read
            // after the candidate query; no sleep or wall-clock skew is needed.
            app.coordination = CoordinationService(store: InMemoryCoordinationStore(), logger: app.logger)
            await app.agentMaintenance.sweepAgentAutoUpdates(
                at: .testing(reportInstant.date.addingTimeInterval(-20)))
            let row = try await self.reload(first, on: app)
            if futureDated {
                #expect(row.updateFailureReason?.contains("stale") == true)
                #expect(row.updateDesiredVersion == Self.target)
                #expect(try await self.reload(second, on: app).updateDesiredVersion == nil)
            } else {
                #expect(row.updateFailureReason == nil)
                #expect(row.updateDesiredVersion == nil)
                #expect(try await self.reload(second, on: app).updateDesiredVersion == Self.target)
            }
        }
    }

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

            try await self.verifyTarget(firstRow, on: app)

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
                timeIntervalSinceNow: -(AgentMaintenanceLoop.autoUpdateHealthBudgetSeconds + 60))
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
                timeIntervalSinceNow: -(AgentMaintenanceLoop.autoUpdateHealthBudgetSeconds + 60))
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

    @Test("offline, unenrolled, and already-converged agents are never assigned")
    func ineligibleAgentsAreSkipped() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let offline = try await self.makeAgent(app: app, org: org, name: "aa-offline", online: false)
            let unenrolled = try await self.makeAgent(app: app, org: org, name: "cc-unenrolled", autoUpdate: false)
            // v-prefixed tag vs bare target: canonical comparison, no update.
            let converged = try await self.makeAgent(app: app, org: org, name: "dd-converged", version: "v1.4.0")

            await self.sweep(app)

            for agent in [offline, unenrolled, converged] {
                let row = try await self.reload(agent, on: app)
                #expect(row.updateDesiredVersion == nil, "\(row.name) must not be assigned")
            }
        }
    }

    // MARK: - Manual assignments (STR-145)

    @Test("a manual assignment is tracked like a rollout one, but never reset as stale")
    func manualAssignmentIsTrackedButNotReset() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            // An operator's "update now" on an agent that isn't even enrolled,
            // pinned to a one-off build the deployment target knows nothing
            // about. The sweep must leave the assignment alone — resetting it
            // as "stale" would cancel the operator's update.
            let manual = try await self.makeAgent(
                app: app, org: org, name: "aa-manual", autoUpdate: false)
            manual.assignUpdate(
                version: "1.9.0-rc1", source: .manual, at: .testing(Date()))
            try await manual.save(on: app.db)

            await self.sweep(app)

            let row = try await self.reload(manual, on: app)
            #expect(row.updateDesiredVersion == "1.9.0-rc1")
            #expect(row.updateAssignmentSource == .manual)

            // And it converges the same way: re-registering at the assigned
            // version clears the assignment.
            row.version = "1.9.0-rc1"
            try await row.save(on: app.db)
            try await self.verifyTarget(row, on: app)
            let converged = try await self.reload(manual, on: app)
            #expect(converged.updateDesiredVersion == nil)
            #expect(converged.updateAssignmentSource == nil)
        }
    }

    @Test("a manual assignment converges even with no deployment target configured")
    func manualAssignmentConvergesWithoutATarget() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            // A dev/main-branch deployment has no target version, so no fleet
            // rollout runs — but that is exactly when explicit-artifact manual
            // updates get used, and their assignment still has to be cleared
            // once the agent comes back on the new build.
            await app.agentMaintenance.setAutoUpdateTargetForTesting(nil)
            let agent = try await self.makeAgent(
                app: app, org: org, name: "aa-manual", autoUpdate: false)
            agent.assignUpdate(
                version: "1.9.0-rc1", source: .manual, at: .testing(Date()))
            try await agent.save(on: app.db)

            await self.sweep(app)
            #expect(try await self.reload(agent, on: app).updateDesiredVersion == "1.9.0-rc1")

            let row = try await self.reload(agent, on: app)
            row.version = "1.9.0-rc1"
            try await row.save(on: app.db)
            try await self.verifyTarget(row, on: app)
            #expect(try await self.reload(agent, on: app).updateDesiredVersion == nil)
        }
    }

    @Test("an in-flight manual update holds the fleet rollout: one agent restarts at a time")
    func manualAssignmentHoldsTheRollout() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let manual = try await self.makeAgent(
                app: app, org: org, name: "aa-manual", autoUpdate: false)
            manual.assignUpdate(
                version: Self.target, source: .manual, at: .testing(Date()))
            try await manual.save(on: app.db)
            let enrolled = try await self.makeAgent(app: app, org: org, name: "bb-enrolled")

            await self.sweep(app)

            #expect(try await self.reload(enrolled, on: app).updateDesiredVersion == nil)
        }
    }

    @Test("a failed manual assignment does not halt the fleet rollout")
    func manualFailureDoesNotHaltTheRollout() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            // The wedge this guards against: an operator updates an agent that
            // isn't enrolled, the agent never comes back, and 600s later the
            // sweep records a failure. If that halted the rollout, no enrolled
            // agent would ever be assigned again — the assignment can't
            // converge (the agent is gone), can't go stale (manual), and can't
            // be re-issued (the endpoint refuses offline agents).
            let manual = try await self.makeAgent(
                app: app, org: org, name: "aa-manual", autoUpdate: false)
            manual.assignUpdate(
                version: "1.9.0-rc1",
                source: .manual,
                artifact: Self.stubArtifact,
                at: .testing(
                    Date(timeIntervalSinceNow: -(AgentMaintenanceLoop.autoUpdateHealthBudgetSeconds + 60))))
            try await manual.save(on: app.db)
            let enrolled = try await self.makeAgent(app: app, org: org, name: "bb-enrolled")

            // First tick records the failure.
            await self.sweep(app)
            let failed = try await self.reload(manual, on: app)
            #expect(failed.updateFailureReason?.contains("did not re-register") == true)
            // The credential does not outlive the update that needed it.
            #expect(failed.updateArtifactOverride == nil)

            // The fleet keeps moving.
            await self.sweep(app)
            #expect(try await self.reload(enrolled, on: app).updateDesiredVersion == Self.target)
        }
    }

    @Test("a failed rollout assignment still halts the fleet")
    func rolloutFailureStillHalts() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            // The other half of the same rule: a rollout failure means the next
            // agent would most likely hit the same bad artifact, so it halts.
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            let second = try await self.makeAgent(app: app, org: org, name: "bb-agent")

            await self.sweep(app)
            let firstRow = try await self.reload(first, on: app)
            #expect(firstRow.updateAssignmentSource == .rollout)
            firstRow.updateAttemptedAt = Date(
                timeIntervalSinceNow: -(AgentMaintenanceLoop.autoUpdateHealthBudgetSeconds + 60))
            try await firstRow.save(on: app.db)

            await self.sweep(app)
            await self.sweep(app)
            #expect(try await self.reload(second, on: app).updateDesiredVersion == nil)
        }
    }

    @Test("target-version recovery withdraws the baseline through existing endpoints", arguments: [false, true])
    func targetVersionRecovery(withdrawEnrollment: Bool) async throws {
        try await withAutoUpdateApp { app, _, org, token in
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            let second = try await self.makeAgent(app: app, org: org, name: "bb-agent")
            first.assignUpdate(version: Self.target, source: .rollout, at: .testing(Date()))
            first.version = Self.target
            first.recordUpdateFailure("target inventory degraded")
            try await first.save(on: app.db)
            #expect(try await self.reload(first, on: app).updateHealthBaseline != nil)

            struct Body: Content {
                let artifactUrl: String
                let sha256: String
                let targetVersion: String
                let force: Bool
            }
            try await app.test(.POST, "/api/agents/\(first.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    Body(
                        artifactUrl: Self.stubArtifact.url, sha256: Self.validDigest,
                        targetVersion: Self.target, force: true))
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("already runs"))
            }
            #expect(try await self.reload(first, on: app).updateFailureReason != nil)
            if withdrawEnrollment {
                try await app.test(.PATCH, "/api/agents/\(first.id!)") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(["autoUpdate": false])
                } afterResponse: { res in
                    #expect(res.status == .ok)
                }
                #expect(try await self.reload(first, on: app).updateHealthBaseline == nil)
                try await app.test(.PATCH, "/api/agents/\(first.id!)") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(["autoUpdate": true])
                } afterResponse: { res in
                    #expect(res.status == .ok)
                }
            } else {
                try await app.test(.DELETE, "/api/agents/\(first.id!)/actions/update") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                } afterResponse: { res in
                    #expect(res.status == .ok)
                }
            }
            let recovered = try await self.reload(first, on: app)
            #expect(recovered.updateDesiredVersion == nil)
            #expect(recovered.updateFailureReason == nil)
            #expect(recovered.updateHealthBaseline == nil)
            await self.sweep(app)
            #expect(try await self.reload(first, on: app).updateDesiredVersion == nil)
            #expect(try await self.reload(second, on: app).updateDesiredVersion == Self.target)
        }
    }

    @Test("cancelling withdraws the assignment, offline agent and all")
    func cancelClearsTheAssignment() async throws {
        try await withAutoUpdateApp { app, _, org, token in
            // Offline on purpose: this is the state a stuck update leaves the
            // agent in, and the one in which re-issuing the update is refused.
            let agent = try await self.makeAgent(
                app: app, org: org, name: "aa-agent", autoUpdate: false, online: false)
            agent.assignUpdate(
                version: "1.9.0-rc1", source: .manual, artifact: Self.stubArtifact,
                at: .testing(Date()))
            agent.recordUpdateFailure("did not re-register at 1.9.0-rc1")
            try await agent.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(AgentResponse.self)
                #expect(body.updateDesiredVersion == nil)
                #expect(body.updateAssignmentSource == nil)
                #expect(body.updateFailureReason == nil)
            }

            let row = try await self.reload(agent, on: app)
            #expect(row.updateDesiredVersion == nil)
            #expect(row.updateArtifactOverride == nil)
            #expect(row.updateAttemptedAt == nil)

            // Idempotent: cancelling again is a no-op success.
            try await app.test(.DELETE, "/api/agents/\(agent.id!)/actions/update") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("withdrawing auto-update leaves an operator's own update assignment alone")
    func withdrawalKeepsManualAssignment() async throws {
        try await withAutoUpdateApp { app, _, org, token in
            let agent = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            agent.assignUpdate(
                version: "1.9.0-rc1", source: .manual, at: .testing(Date()))
            try await agent.save(on: app.db)

            try await app.test(.PATCH, "/api/agents/\(agent.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["autoUpdate": false])
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(AgentResponse.self)
                #expect(!body.autoUpdate)
                // Withdrawing from the fleet rollout is not a cancellation of
                // an update the operator asked for directly — that path needs
                // no enrollment in the first place.
                #expect(body.updateDesiredVersion == "1.9.0-rc1")
                #expect(body.updateAssignmentSource == "manual")
            }
        }
    }

    @Test("an unresolvable artifact defers assignment instead of burning the agent's budget")
    func unresolvableArtifactDefersAssignment() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            app.agentArtifactResolver = AgentArtifactResolver { _, _, _ in
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

            let sync = try await app.desiredStateAssembler.assemble(
                agentId: agent.requireID().uuidString)

            let update = try #require(sync.desiredAgentUpdate)
            #expect(update.targetVersion == Self.target)
            #expect(update.artifactURL == Self.stubArtifact.url)
            #expect(update.sha256 == Self.validDigest)
            #expect(update.artifactKind == .tarball)
            #expect(update.tarballMember == "strato-agent")
        }
    }

    @Test("the sync omits the update for unassigned and converged agents")
    func syncOmitsUpdateWhenNotActionable() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let unassigned = try await self.makeAgent(app: app, org: org, name: "aa-unassigned")

            let converged = try await self.makeAgent(app: app, org: org, name: "bb-converged", version: "v1.4.0")
            converged.updateDesiredVersion = Self.target
            try await converged.save(on: app.db)

            for agent in [unassigned, converged] {
                let sync = try await app.desiredStateAssembler.assemble(
                    agentId: agent.requireID().uuidString)
                #expect(sync.desiredAgentUpdate == nil, "\(agent.name) must not be sent an update")
            }
        }
    }

    @Test("an artifact-resolution outage omits the update but not the sync")
    func assemblySurvivesResolutionOutage() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            app.agentArtifactResolver = AgentArtifactResolver { _, _, _ in
                throw Abort(.badGateway, reason: "release host down")
            }
            let agent = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            agent.updateDesiredVersion = Self.target
            try await agent.save(on: app.db)

            let sync = try await app.desiredStateAssembler.assemble(
                agentId: agent.requireID().uuidString)
            #expect(sync.desiredAgentUpdate == nil)
        }
    }

    @Test("post-update regression halts only automatic assignments", arguments: [false, true])
    func postUpdateRegression(manual: Bool) async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            let second = try await self.makeAgent(app: app, org: org, name: "bb-agent")
            first.tpmCapable = true
            first.assignUpdate(version: Self.target, source: manual ? .manual : .rollout, at: .testing(now))
            try await first.save(on: app.db)
            let row = try await self.reload(first, on: app)
            #expect(row.updateHealthBaseline?.capabilities.contains("tpm") == true)
            row.version = Self.target
            row.tpmCapable = false
            self.targetHealth(row, at: now.addingTimeInterval(1), register: true)
            try await row.save(on: app.db)
            await self.sweep(app, at: .testing(now.addingTimeInterval(1)))
            let failed = try await self.reload(first, on: app)
            #expect(failed.updateFailureReason?.contains("tpm") == true)
            #expect(failed.updateDesiredVersion == Self.target)
            #expect(try await self.reload(second, on: app).updateDesiredVersion == (manual ? Self.target : nil))
            // Target equality and recovery cannot erase a terminal failure.
            failed.tpmCapable = true
            try await failed.save(on: app.db)
            await self.sweep(app, at: .testing(now.addingTimeInterval(2)))
            #expect(try await self.reload(first, on: app).updateFailureReason == failed.updateFailureReason)
        }
    }

    @Test(
        "degraded dependency health fails even when placement still allows it",
        arguments: [NodeDependencyFunctionalState.degraded, .unhealthy])
    func dependencyRegression(state: NodeDependencyFunctionalState) async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            let second = try await self.makeAgent(app: app, org: org, name: "bb-agent")
            func sample(_ state: NodeDependencyFunctionalState) -> NodeDependencyObservation {
                NodeDependencyObservation(
                    id: .libvirt, role: .compute, desiredState: .required,
                    ownership: .observeOnly, supervisorState: .active, compatibility: .compatible,
                    functionalState: state, checkedAt: now, affectedCapabilities: [.qemuPlacement])
            }
            first.dependencyObservations = [sample(.healthy)]
            first.dependencyObservationsReceivedAt = now
            first.hypervisors = [HypervisorSupport(type: .qemu, available: true, accelerated: true)]
            first.assignUpdate(version: Self.target, source: .rollout, at: .testing(now))
            first.version = Self.target
            first.dependencyObservations = [sample(state)]
            self.targetHealth(first, at: now.addingTimeInterval(1), register: true)
            try await first.save(on: app.db)
            await self.sweep(app, at: .testing(now.addingTimeInterval(1)))
            #expect(try await self.reload(first, on: app).updateFailureReason?.contains("libvirt") == true)
            #expect(try await self.reload(second, on: app).updateDesiredVersion == nil)
        }
    }

    @Test(
        "backend subcapabilities are retained",
        arguments: ["backend", "accelerated", "snapshots", "vsock", "guest_exec", "volume_io_limits"])
    func backendRegression(lost: String) async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            first.hypervisors = [
                HypervisorSupport(
                    type: .firecracker, available: true, accelerated: true,
                    supportsSnapshots: true, supportsVsock: true, supportsGuestExec: true, supportsVolumeIOLimits: true)
            ]
            first.assignUpdate(version: Self.target, source: .rollout, at: .testing(now))
            first.version = Self.target
            first.hypervisors = [
                HypervisorSupport(
                    type: .firecracker, available: lost != "backend",
                    accelerated: lost != "accelerated", supportsSnapshots: lost != "snapshots",
                    supportsVsock: lost != "vsock", supportsGuestExec: lost != "guest_exec",
                    supportsVolumeIOLimits: lost != "volume_io_limits")
            ]
            self.targetHealth(first, at: now.addingTimeInterval(1), register: true)
            try await first.save(on: app.db)
            await self.sweep(app, at: .testing(now.addingTimeInterval(1)))
            #expect(
                try await self.reload(first, on: app).updateFailureReason?.contains("hypervisor:firecracker") == true)
        }
    }

    @Test("registration without inventory cannot converge and eventually exhausts its budget")
    func missingTargetEvidence() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            let second = try await self.makeAgent(app: app, org: org, name: "bb-agent")
            first.assignUpdate(version: Self.target, source: .rollout, at: .testing(now))
            first.version = Self.target
            first.updateTargetRegisteredAt = now.addingTimeInterval(1)
            first.dependencyObservationsReceivedAt = now.addingTimeInterval(1)
            first.lastHeartbeat = now.addingTimeInterval(1)
            try await first.save(on: app.db)
            await self.sweep(app, at: .testing(now.addingTimeInterval(60)))
            #expect(try await self.reload(first, on: app).updateVerificationStartedAt == nil)
            await self.sweep(app, at: .testing(now.addingTimeInterval(601)))
            #expect(try await self.reload(first, on: app).updateFailureReason?.contains("verification") == true)
            #expect(try await self.reload(second, on: app).updateDesiredVersion == nil)
        }
    }

    @Test("a restarted assignment clock cannot reuse an earlier health interval")
    func retryRestartsVerification() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            first.assignUpdate(version: Self.target, source: .rollout, at: .testing(now))
            first.version = Self.target
            first.updateVerificationStartedAt = now.addingTimeInterval(1)
            first.updateTargetRegisteredAt = now.addingTimeInterval(1)
            first.updateAttemptedAt = now.addingTimeInterval(70)  // Restart a retained assignment's clock.
            self.targetHealth(first, at: now.addingTimeInterval(70))
            try await first.save(on: app.db)
            await self.sweep(app, at: .testing(now.addingTimeInterval(70)))
            let row = try await self.reload(first, on: app)
            #expect(row.updateDesiredVersion == Self.target)
            #expect(row.updateVerificationStartedAt == now.addingTimeInterval(70))
        }
    }

    @Test("legacy target assignments direct operators to review health and cancel")
    func missingBaseline() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent", version: Self.target)
            first.updateDesiredVersion = Self.target
            try await first.save(on: app.db)
            await self.sweep(app)
            #expect(try await self.reload(first, on: app).updateFailureReason?.contains("explicitly cancel") == true)
        }
    }

    @Test("parked assignments still require fresh target health")
    func parkedVerification() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            agent.assignUpdate(version: Self.target, source: .rollout, at: .testing(Date()))
            agent.updateAttemptedAt = nil
            agent.version = Self.target
            try await self.verifyTarget(agent, on: app)
            #expect(try await self.reload(agent, on: app).updateDesiredVersion == nil)
        }
    }

    @Test("target registration starts evidence again without erasing failure")
    func registrationVerification() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let agent = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            agent.assignUpdate(version: Self.target, source: .rollout, at: .testing(now))
            agent.recordUpdateFailure("terminal failure")
            agent.updateVerificationStartedAt = now
            agent.updateInventoryReceivedAt = now
            let registration = AgentRegisterMessage(
                agentId: try agent.requireID().uuidString, hostname: agent.hostname, version: Self.target,
                resources: agent.resources, architecture: .x86_64, hypervisors: [])
            agent.apply(registration: registration, dependencyObservations: [], receivedAt: now.addingTimeInterval(1))
            #expect(agent.updateTargetRegisteredAt == now.addingTimeInterval(1))
            #expect(agent.updateVerificationStartedAt == nil)
            #expect(agent.updateInventoryReceivedAt == nil)
            #expect(agent.updateFailureReason == "terminal failure")
        }
    }

    @Test("incomplete and unroutable inventory fail target verification", arguments: [false, true])
    func inventoryRegression(complete: Bool) async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            let second = try await self.makeAgent(app: app, org: org, name: "bb-agent")
            first.assignUpdate(version: Self.target, source: .rollout, at: .testing(now))
            first.version = Self.target
            self.targetHealth(first, at: now.addingTimeInterval(1), register: true)
            first.manifestInventoryComplete = complete
            first.manifestStatusReason = "unroutable workload"
            try await first.save(on: app.db)
            await self.sweep(app, at: .testing(now.addingTimeInterval(1)))
            #expect(try await self.reload(first, on: app).updateFailureReason?.contains("inventory") == true)
            #expect(try await self.reload(second, on: app).updateDesiredVersion == nil)
        }
    }

    @Test("fresh later evidence and the full interval are required; capability gain passes")
    func verificationInterval() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            first.assignUpdate(version: Self.target, source: .rollout, at: .testing(now))
            first.version = Self.target
            first.tpmCapable = true  // Newly gained capability is allowed.
            first.updateTargetRegisteredAt = now.addingTimeInterval(1)
            first.dependencyObservationsReceivedAt = now  // Pre-update evidence cannot pass.
            try await first.save(on: app.db)
            await self.sweep(app, at: .testing(now.addingTimeInterval(1)))
            #expect(try await self.reload(first, on: app).updateVerificationStartedAt == nil)
            let start = now.addingTimeInterval(2)
            self.targetHealth(first, at: start)
            try await first.save(on: app.db)
            await self.sweep(app, at: .testing(start))
            var row = try await self.reload(first, on: app)
            #expect(row.updateVerificationStartedAt == start)
            let before = start.addingTimeInterval(59)
            self.targetHealth(row, at: before)
            try await row.save(on: app.db)
            await self.sweep(app, at: .testing(before))
            row = try await self.reload(first, on: app)
            #expect(row.updateDesiredVersion == Self.target)
            // Passage of time alone cannot replace a sample at the far boundary.
            await self.sweep(app, at: .testing(start.addingTimeInterval(60)))
            #expect(try await self.reload(first, on: app).updateDesiredVersion == Self.target)
            self.targetHealth(row, at: start.addingTimeInterval(60))
            try await row.save(on: app.db)
            await self.sweep(app, at: .testing(start.addingTimeInterval(60)))
            row = try await self.reload(first, on: app)
            #expect(row.updateDesiredVersion == nil)
            #expect(row.updateHealthBaseline == nil)
            #expect(row.updateTargetRegisteredAt == nil)
            #expect(row.updateVerificationStartedAt == nil)
        }
    }

    @Test(
        "disappearance and stale inventory or dependencies fail an active window",
        arguments: ["heartbeat", "inventory", "dependencies"])
    func staleVerification(signal: String) async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            let second = try await self.makeAgent(app: app, org: org, name: "bb-agent")
            first.assignUpdate(version: Self.target, source: .rollout, at: .testing(now))
            first.version = Self.target
            let start = now.addingTimeInterval(1)
            self.targetHealth(first, at: start, register: true)
            try await first.save(on: app.db)
            await self.sweep(app, at: .testing(start))
            let row = try await self.reload(first, on: app)
            let end = start.addingTimeInterval(60)
            self.targetHealth(row, at: end)
            switch signal {
            case "heartbeat": row.lastHeartbeat = start
            case "inventory": row.updateInventoryReceivedAt = start
            default: row.dependencyObservationsReceivedAt = start
            }
            try await row.save(on: app.db)
            await self.sweep(app, at: .testing(end))
            #expect(try await self.reload(first, on: app).updateFailureReason?.contains("stale") == true)
            #expect(try await self.reload(second, on: app).updateDesiredVersion == nil)
        }
    }

    @Test(
        "Convergence rechecks reports and assignments committed after its snapshot",
        arguments: ["failure", "inventory", "assignment"])
    func convergenceRechecksCurrentAgent(change: String) async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let first = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            let second = try await self.makeAgent(app: app, org: org, name: "bb-agent")
            second.lastHeartbeat = now
            try await second.save(on: app.db)
            first.assignUpdate(version: Self.target, source: .rollout, at: .testing(now.addingTimeInterval(-120)))
            first.version = Self.target
            first.updateTargetRegisteredAt = now.addingTimeInterval(-119)
            first.updateVerificationStartedAt = now.addingTimeInterval(-60)
            self.targetHealth(first, at: now)
            try await first.save(on: app.db)
            let id = try first.requireID()
            let injected = Mutex(false)
            app.coordination = CoordinationService(store: InMemoryCoordinationStore(), logger: app.logger)
            await app.agentMaintenance.sweepAgentAutoUpdates(
                at: .testing(now),
                currentInstant: { db in
                    // This hook runs after candidates were loaded, before convergence.
                    let shouldInject = injected.withLock { value in
                        guard !value else { return false }
                        value = true
                        return true
                    }
                    guard shouldInject else { return .testing(now) }
                    let current = try #require(try await Agent.find(id, on: db))
                    switch change {
                    case "failure": current.recordUpdateFailure("late terminal failure")
                    case "inventory": current.manifestStatusReason = "late inventory degradation"
                    default: current.assignUpdate(version: "different-target", source: .manual, at: .testing(now))
                    }
                    try await current.save(on: db)
                    return .testing(now)
                })
            let retained = try await self.reload(first, on: app)
            #expect(retained.updateDesiredVersion == (change == "assignment" ? "different-target" : Self.target))
            if change == "failure" { #expect(retained.updateFailureReason == "late terminal failure") }
            if change == "inventory" { #expect(retained.manifestStatusReason == "late inventory degradation") }
            #expect(try await self.reload(second, on: app).updateDesiredVersion == nil)
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
            #expect(row.updateInventoryReceivedAt != nil)
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

    @Test("re-enrolling with an assignment in place restarts the health budget")
    func reenrollRestartsTheBudgetClock() async throws {
        try await withAutoUpdateApp { app, _, org, token in
            // Clearing the failure alone is a retry that never had a chance:
            // the original `updateAttemptedAt` is already past the budget, so
            // the next sweep tick re-records the same failure immediately.
            let agent = try await self.makeAgent(app: app, org: org, name: "aa-agent", autoUpdate: false)
            let staleClock = Date(timeIntervalSinceNow: -(AgentMaintenanceLoop.autoUpdateHealthBudgetSeconds + 60))
            agent.assignUpdate(
                version: Self.target, source: .rollout, at: .testing(staleClock))
            agent.recordUpdateFailure("did not re-register at \(Self.target)")
            try await agent.save(on: app.db)

            try await app.test(.PATCH, "/api/agents/\(agent.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["autoUpdate": true])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let after = try await self.reload(agent, on: app)
            #expect(after.updateFailureReason == nil)
            #expect((after.updateAttemptedAt ?? staleClock) > staleClock)

            // And the retry survives a sweep instead of re-failing on the spot.
            await self.sweep(app)
            #expect(try await self.reload(agent, on: app).updateFailureReason == nil)
        }
    }

    @Test("an agent-reported failure drops the pinned artifact")
    func reportedFailureDropsTheArtifact() async throws {
        try await withAutoUpdateApp { app, _, org, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "aa-agent")
            agent.assignUpdate(
                version: Self.target, source: .manual, artifact: Self.stubArtifact,
                at: .testing(Date()))
            try await agent.save(on: app.db)

            let failed = ObservedAgentUpdateStatus(
                targetVersion: Self.target,
                disposition: ObservedAgentUpdateStatus.dispositionFailed,
                reason: "artifact checksum mismatch"
            )
            await app.agentService.applyObservedStateReport(
                try self.report(from: agent, status: failed), fromAgentKey: agent.identity.key)

            let row = try await self.reload(agent, on: app)
            #expect(row.updateFailureReason == "artifact checksum mismatch")
            #expect(row.updateArtifactOverride == nil)
            // The assignment itself stays: it is what the operator sees, and
            // what a returning agent could still converge on.
            #expect(row.updateDesiredVersion == Self.target)
        }
    }
}
