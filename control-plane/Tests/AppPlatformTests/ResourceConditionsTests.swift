import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting
import AppTestSupport

@testable import App

/// Tests for the `conditions` block VM and sandbox responses project (ADR 0001
/// stage 1, STR-142): the derivation itself, and the observed-report path that
/// mirrors the agent's convergence progress onto the row it reads from.
@Suite("Resource Conditions Tests", .serialized)
final class ResourceConditionsTests {

    // MARK: - Harness

    private func withTestApp(
        _ test: (Application, User, Project) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "conditionsuser",
                email: "conditions@example.com",
                displayName: "Conditions User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Conditions Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Conditions Project",
                description: "Project for conditions tests",
                organization: org
            )

            try await test(app, user, project)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    private func registerAgent(
        app: Application,
        named agentName: String,
        capabilities: [String]
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: agentName,
            hostname: "test-host",
            version: "1.0.0",
            capabilities: capabilities,
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: WireProtocol.currentVersion,
            sandboxCapable: capabilities.contains("firecracker")
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: agentName,
            organizationScope: orgID.map { .organization($0) })
        return agentUUID.uuidString
    }

    private func report(
        agentId: String,
        vms: [ObservedVMState] = [],
        sandboxes: [ObservedSandboxState] = []
    ) throws -> MessageEnvelope {
        let report = ObservedStateReport(
            agentId: agentId,
            vms: vms,
            sandboxes: sandboxes,
            resources: AgentResources(
                totalCPU: 16, availableCPU: 12,
                totalMemory: 1 << 34, availableMemory: 1 << 33,
                totalDisk: 1 << 40, availableDisk: 1 << 39
            )
        )
        return try MessageEnvelope(message: report)
    }

    /// A subscription to every event, so the applier tests below can tell which
    /// convergence branch ran. The row state a success and a failure leave on a
    /// *running* VM is otherwise identical — `revertDesiredToObserved` has
    /// nothing to abandon when the observed status already satisfies the desired
    /// one — so the outbox is the only witness.
    /// The convergence outcomes in the outbox, in order. Filtered because agent
    /// registration puts an `agent.connected` row there too, and that is not
    /// what any of these tests is about.
    private func mutationOutcomes(app: Application) async throws -> [String] {
        try await WebhookDelivery.query(on: app.db)
            .sort(\.$createdAt)
            .all()
            .map(\.eventType)
            .filter { $0.hasPrefix("operation.") }
    }

    private func subscribeToEverything(app: Application) async throws {
        let org = try #require(await Organization.query(on: app.db).sort(\.$createdAt).first())
        let user = try #require(await User.query(on: app.db).sort(\.$createdAt).first())
        let subscription = WebhookSubscription(
            organizationID: try org.requireID(),
            projectID: nil,
            name: "conditions hook",
            url: "http://127.0.0.1:1/hook",
            eventTypes: [],
            signingSecret: try app.secretsEncryption.encrypt("whsec_test_secret"),
            createdByID: try user.requireID()
        )
        try await subscription.save(on: app.db)
    }

    // MARK: - Derivation

    @Test("A VM whose agent has caught up and whose desired status is satisfied is converged")
    func vmConverged() async throws {
        try await withTestApp { app, _, project in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.observedGeneration = vm.generation

            let conditions = vm.conditions
            #expect(conditions.converged)
            #expect(conditions.targetGeneration == vm.generation)
            #expect(conditions.observedGeneration == vm.generation)
            #expect(conditions.phase == nil)
            #expect(conditions.degraded == nil)
        }
    }

    @Test("An acknowledged generation the observed status does not satisfy is not converged")
    func vmAcknowledgedButUnsatisfied() async throws {
        try await withTestApp { app, _, project in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.error)
            vm.observedGeneration = vm.generation

            // Both halves matter: the agent acknowledged the generation, but
            // what it observes is not what was asked for.
            #expect(!vm.conditions.converged)
        }
    }

    @Test("A VM being deleted never reads as converged")
    func vmPendingDeleteIsNeverConverged() async throws {
        try await withTestApp { app, _, project in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            vm.setFixtureDesiredStatus(.absent)
            vm.setStatus(.shutdown)
            vm.observedGeneration = vm.generation

            // Absence is confirmed by omission from the agent's report, which
            // removes the row — a still-present row has not converged.
            #expect(!vm.conditions.converged)
        }
    }

    @Test("A failure the current generation superseded still reports its own generation")
    func degradedCarriesTheFailingGeneration() async throws {
        try await withTestApp { app, _, project in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            vm.generation = 14
            vm.observedGeneration = 12
            vm.convergencePhase = "downloading image"
            vm.lastError = "image download failed"
            vm.failedGeneration = 13

            let conditions = vm.conditions
            #expect(!conditions.converged)
            #expect(conditions.targetGeneration == 14)
            #expect(conditions.observedGeneration == 12)
            #expect(conditions.phase == "downloading image")
            #expect(conditions.degraded?.reason == "image download failed")
            #expect(conditions.degraded?.sinceGeneration == 13)
        }
    }

    @Test("An error with no failing generation is not reported as degraded")
    func degradedRequiresBothHalves() async throws {
        try await withTestApp { app, _, project in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            vm.lastError = "something went wrong"
            vm.failedGeneration = nil

            // Without a generation the reason can't be placed against
            // `targetGeneration`, which is the only thing that makes it useful.
            #expect(vm.conditions.degraded == nil)
        }
    }

    @Test("A failure at the current generation is not converged")
    func failureAtCurrentGenerationIsNotConverged() async throws {
        try await withTestApp { app, _, project in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.generation = 5
            vm.observedGeneration = 5
            vm.lastError = "resize failed: no space left on device"
            vm.failedGeneration = 5

            // STR-191, from the e2e suite: generation 5 was applied — by the
            // *boot* — and then the drift-correcting resize the agent planned at
            // the same generation failed. The agent's `observedGeneration` is
            // honest; what would be dishonest is calling that converged.
            let conditions = vm.conditions
            #expect(!conditions.converged)
            #expect(conditions.degraded?.sinceGeneration == 5)
            #expect(conditions.degraded?.reason == "resize failed: no space left on device")
        }
    }

    @Test("A failure an older generation left behind does not un-converge the current one")
    func supersededFailureStillReadsConverged() async throws {
        try await withTestApp { app, _, project in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.generation = 6
            vm.observedGeneration = 6
            vm.lastError = "image download failed"
            vm.failedGeneration = 5

            // The clause excludes a failure at *this* generation, not the
            // presence of one: a failure a newer mutation already retried past
            // is documented to stand alongside a converged resource.
            let conditions = vm.conditions
            #expect(conditions.converged)
            #expect(conditions.degraded?.sinceGeneration == 5)
        }
    }

    @Test("An unreportable error does not un-converge either")
    func errorWithoutGenerationDoesNotUnconverge() async throws {
        try await withTestApp { app, _, project in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.generation = 5
            vm.observedGeneration = 5
            vm.lastError = "something went wrong"
            vm.failedGeneration = nil

            // The clause reads the *degraded condition*, not the raw column, so
            // it stays exactly the negation of "degraded names the target". An
            // error with nowhere to place it is not a verdict.
            #expect(vm.conditions.converged)
            #expect(vm.conditions.degraded == nil)
        }
    }

    @Test("converged and degraded are never both an answer")
    func convergedAndDegradedAreMutuallyExclusive() async throws {
        try await withTestApp { app, _, project in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.generation = 5

            // The invariant itself rather than one instance of it: whatever the
            // agent reports, a client reading the documented rule must never get
            // two answers.
            for observed in Int64(4)...Int64(6) {
                for failed in Int64(4)...Int64(6) {
                    vm.observedGeneration = observed
                    vm.lastError = "convergence failed"
                    vm.failedGeneration = failed

                    let conditions = vm.conditions
                    #expect(
                        !(conditions.converged
                            && conditions.degraded?.sinceGeneration == conditions.targetGeneration),
                        "observed \(observed), failed \(failed)")
                }
            }
        }
    }

    @Test("isConverged and conditions.converged answer alike for a VM and a sandbox")
    func bothReadersAgree() async throws {
        try await withTestApp { app, _, project in
            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "cond-vm", project: project)
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.generation = 5
            vm.observedGeneration = 5
            #expect(vm.isConverged == vm.conditions.converged)
            #expect(vm.isConverged)

            // The reconciliation paths read `isConverged` and clients read
            // `conditions.converged`. They are one derivation now (STR-191);
            // before, each family wrote its own and they had already drifted.
            vm.lastError = "resize failed"
            vm.failedGeneration = 5
            #expect(vm.isConverged == vm.conditions.converged)
            #expect(!vm.isConverged)

            let sandbox = try await builder.createSandbox(name: "cond-sandbox", project: project)
            sandbox.setFixtureDesiredStatus(.running)
            sandbox.setStatus(.running)
            sandbox.generation = 3
            sandbox.observedGeneration = 3
            #expect(sandbox.isConverged == sandbox.conditions.converged)
            #expect(sandbox.isConverged)

            sandbox.lastError = "manifest unknown"
            sandbox.failedGeneration = 3
            #expect(sandbox.isConverged == sandbox.conditions.converged)
            #expect(!sandbox.isConverged)
        }
    }

    @Test("Sandboxes derive the same block from their own generation pair")
    func sandboxConditions() async throws {
        try await withTestApp { app, _, project in
            let sandbox = try await TestDataBuilder(db: app.db)
                .createSandbox(name: "cond-sandbox", project: project)
            sandbox.setFixtureDesiredStatus(.running)
            sandbox.setStatus(.running)
            sandbox.observedGeneration = sandbox.generation
            #expect(sandbox.conditions.converged)

            let acknowledged = sandbox.observedGeneration
            sandbox.setFixtureDesiredStatus(.stopped)  // bumps past what the agent acknowledged
            #expect(!sandbox.conditions.converged)
            #expect(sandbox.conditions.targetGeneration == acknowledged + 1)
            #expect(sandbox.conditions.observedGeneration == acknowledged)
        }
    }

    // MARK: - Projection into responses

    @Test("VM and sandbox responses carry the conditions block")
    func responsesCarryConditions() async throws {
        try await withTestApp { app, _, project in
            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "cond-vm", project: project)
            vm.setFixtureDesiredStatus(.running)
            vm.convergencePhase = "downloading image"
            try await vm.save(on: app.db)

            let vmJSON =
                try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(VMDetailResponse(from: vm))) as? [String: Any]
            let vmConditions = try #require(vmJSON?["conditions"] as? [String: Any])
            #expect(vmConditions["converged"] as? Bool == false)
            #expect(vmConditions["targetGeneration"] as? Int == Int(vm.generation))
            #expect(vmConditions["observedGeneration"] as? Int == 0)
            #expect(vmConditions["phase"] as? String == "downloading image")
            // A nil condition is an absent key, not an explicit null.
            #expect(!vmConditions.keys.contains("degraded"))

            let sandbox = try await builder.createSandbox(name: "cond-sandbox", project: project)
            sandbox.setFixtureDesiredStatus(.running)
            sandbox.lastError = "pull failed"
            sandbox.failedGeneration = sandbox.generation
            try await sandbox.save(on: app.db)

            let sandboxJSON =
                try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(SandboxDetailResponse(from: sandbox))) as? [String: Any]
            let sandboxConditions = try #require(sandboxJSON?["conditions"] as? [String: Any])
            let degraded = try #require(sandboxConditions["degraded"] as? [String: Any])
            #expect(degraded["reason"] as? String == "pull failed")
            #expect(degraded["sinceGeneration"] as? Int == Int(sandbox.generation))
        }
    }

    // MARK: - Persistence from observed reports

    @Test("A converging report records the agent's phase on the VM row")
    func convergingReportRecordsPhase() async throws {
        try await withTestApp { app, _, project in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            let agentId = try await self.registerAgent(
                app: app, named: "cond-agent", capabilities: ["qemu"])
            vm.hypervisorId = agentId
            vm.setFixtureDesiredStatus(.running)
            try await vm.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!, status: .unknown, observedGeneration: 0,
                        convergencePhase: "downloading image")
                ]
            )
            await app.agentService.applyObservedStateReport(
                envelope, fromAgentKey: agentKey("cond-agent"))

            // The row is otherwise untouched — a converging entry is progress
            // only — but the phase is now readable without polling anything.
            let refreshed = try #require(await VM.find(vm.id, on: app.db))
            #expect(refreshed.status == .created)
            #expect(refreshed.conditions.phase == "downloading image")
            #expect(!refreshed.conditions.converged)
        }
    }

    @Test("A convergence failure lands as degraded, and survives the generation bump that follows")
    func failureRecordsDegraded() async throws {
        try await withTestApp { app, user, project in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            let agentId = try await self.registerAgent(
                app: app, named: "cond-agent", capabilities: ["qemu"])
            vm.hypervisorId = agentId
            vm.setFixtureDesiredStatus(.running)  // generation 1
            try await vm.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!, status: .shutdown, observedGeneration: 0,
                        lastError: "boot failed: no bootable device",
                        failedGeneration: 1)
                ]
            )
            await app.agentService.applyObservedStateReport(
                envelope, fromAgentKey: agentKey("cond-agent"))

            // Failing the operation realigns desired state with reality, which
            // bumps the generation — so the degraded condition is deliberately
            // *behind* the target it is reported against, exactly as it would
            // be while a retry is in flight.
            let refreshed = try #require(await VM.find(vm.id, on: app.db))
            #expect(refreshed.conditions.degraded?.reason == "boot failed: no bootable device")
            #expect(refreshed.conditions.degraded?.sinceGeneration == 1)
            #expect(refreshed.conditions.targetGeneration == 2)
            #expect(!refreshed.conditions.converged)
        }
    }

    @Test("A successful convergence clears a recorded failure")
    func successClearsDegraded() async throws {
        try await withTestApp { app, _, project in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            let agentId = try await self.registerAgent(
                app: app, named: "cond-agent", capabilities: ["qemu"])
            vm.hypervisorId = agentId
            vm.setFixtureDesiredStatus(.running)  // generation 1
            vm.lastError = "boot failed: no bootable device"
            vm.failedGeneration = 1
            vm.convergencePhase = "starting"
            try await vm.save(on: app.db)

            // The retry succeeded: the agent's report carries neither a phase
            // nor an error, and both must be dropped rather than left stale.
            let envelope = try self.report(
                agentId: agentId,
                vms: [ObservedVMState(vmId: vm.id!, status: .running, observedGeneration: 1)]
            )
            await app.agentService.applyObservedStateReport(
                envelope, fromAgentKey: agentKey("cond-agent"))

            let refreshed = try #require(await VM.find(vm.id, on: app.db))
            #expect(refreshed.conditions.converged)
            #expect(refreshed.conditions.phase == nil)
            #expect(refreshed.conditions.degraded == nil)
        }
    }

    @Test("A VM the agent stops reporting loses its stale progress")
    func absenceClearsStaleProgress() async throws {
        try await withTestApp { app, _, project in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            let agentId = try await self.registerAgent(
                app: app, named: "cond-agent", capabilities: ["qemu"])
            vm.hypervisorId = agentId
            vm.setFixtureDesiredStatus(.running)
            vm.convergencePhase = "downloading image"
            vm.lastError = "transient download error"
            vm.failedGeneration = 1
            try await vm.save(on: app.db)

            // The agent restarted: it still holds the VM's placement but has
            // lost the in-memory progress, so its report mentions nothing.
            // (`.created` is below the escalation bar, so the row survives.)
            await app.agentService.applyObservedStateReport(
                try self.report(agentId: agentId), fromAgentKey: agentKey("cond-agent"))

            let refreshed = try #require(await VM.find(vm.id, on: app.db))
            #expect(refreshed.status == .created)
            #expect(refreshed.conditions.phase == nil)
            #expect(refreshed.conditions.degraded == nil)
        }
    }

    @Test("Sandbox reports record convergence progress the same way")
    func sandboxReportRecordsProgress() async throws {
        try await withTestApp { app, _, project in
            let sandbox = try await TestDataBuilder(db: app.db)
                .createSandbox(name: "cond-sandbox", project: project)
            let agentId = try await self.registerAgent(
                app: app, named: "cond-fc-agent", capabilities: ["firecracker"])
            sandbox.hypervisorId = agentId
            sandbox.setFixtureDesiredStatus(.running)  // generation 1
            try await sandbox.save(on: app.db)

            let converging = try self.report(
                agentId: agentId,
                sandboxes: [
                    ObservedSandboxState(
                        sandboxId: sandbox.id!, status: .unknown, observedGeneration: 0,
                        convergencePhase: "pulling image")
                ]
            )
            await app.agentService.applyObservedStateReport(
                converging, fromAgentKey: agentKey("cond-fc-agent"))
            var refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(refreshed.conditions.phase == "pulling image")
            #expect(refreshed.conditions.degraded == nil)

            let failed = try self.report(
                agentId: agentId,
                sandboxes: [
                    ObservedSandboxState(
                        sandboxId: sandbox.id!, status: .error, observedGeneration: 0,
                        lastError: "manifest unknown",
                        failedGeneration: 1)
                ]
            )
            await app.agentService.applyObservedStateReport(
                failed, fromAgentKey: agentKey("cond-fc-agent"))
            refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(refreshed.conditions.phase == nil)
            #expect(refreshed.conditions.degraded?.reason == "manifest unknown")
            #expect(refreshed.conditions.degraded?.sinceGeneration == 1)
        }
    }

    // MARK: - A generation applied and then failed at (STR-191)

    @Test("A report that advances the generation and fails at it records the failure, not success")
    func advanceAndFailInOneReportRecordsFailure() async throws {
        try await withTestApp { app, user, project in
            try await self.subscribeToEverything(app: app)
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            let agentId = try await self.registerAgent(
                app: app, named: "cond-agent", capabilities: ["qemu"])
            vm.hypervisorId = agentId
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.generation = 5
            vm.observedGeneration = 4
            vm.extendConvergenceDeadline(by: 120)
            try await vm.save(on: app.db)
            _ = try await ResourceEvent.record(
                .resize, resourceKind: .virtualMachine, resourceID: try vm.requireID(),
                actor: .user(try user.requireID()), on: app.db)

            // One report carrying both halves: the boot applied generation 5,
            // the resize planned at the same generation failed. The applier used
            // to take the success branch here — `observedGeneration` advanced and
            // the status satisfied the desired one — and the `else if` that
            // records the failure never ran, so the user was told the mutation
            // completed.
            let envelope = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!, status: .running, observedGeneration: 5,
                        lastError: "resize failed: no space left on device",
                        failedGeneration: 5)
                ]
            )
            await app.agentService.applyObservedStateReport(
                envelope, fromAgentKey: agentKey("cond-agent"))

            let refreshed = try #require(await VM.find(vm.id, on: app.db))
            #expect(!refreshed.conditions.converged)
            #expect(refreshed.conditions.degraded?.sinceGeneration == 5)
            #expect(
                refreshed.conditions.degraded?.reason == "resize failed: no space left on device")

            #expect(try await self.mutationOutcomes(app: app) == ["operation.failed"])
        }
    }

    @Test("A drift-correcting failure degrades a VM that had already converged")
    func driftCorrectingFailureDegradesConvergedVM() async throws {
        try await withTestApp { app, user, project in
            try await self.subscribeToEverything(app: app)
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            let agentId = try await self.registerAgent(
                app: app, named: "cond-agent", capabilities: ["qemu"])
            vm.hypervisorId = agentId
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.generation = 5
            vm.observedGeneration = 5  // the boot already converged and was reported
            try await vm.save(on: app.db)
            _ = try await ResourceEvent.record(
                .resize, resourceKind: .virtualMachine, resourceID: try vm.requireID(),
                actor: .user(try user.requireID()), on: app.db)

            let failing = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!, status: .running, observedGeneration: 5,
                        lastError: "resize failed: no space left on device",
                        failedGeneration: 5)
                ]
            )
            await app.agentService.applyObservedStateReport(
                failing, fromAgentKey: agentKey("cond-agent"))

            var refreshed = try #require(await VM.find(vm.id, on: app.db))
            #expect(!refreshed.conditions.converged)
            #expect(refreshed.conditions.degraded?.sinceGeneration == 5)
            #expect(try await self.mutationOutcomes(app: app) == ["operation.failed"])

            // The agent keeps restating the same error on every heartbeat; only
            // the transition is reportable.
            await app.agentService.applyObservedStateReport(
                failing, fromAgentKey: agentKey("cond-agent"))
            refreshed = try #require(await VM.find(vm.id, on: app.db))
            #expect(!refreshed.conditions.converged)
            #expect(try await self.mutationOutcomes(app: app) == ["operation.failed"])
        }
    }

    @Test("A retry that succeeds at the same generation re-converges without a second completion")
    func recoveryAtTheSameGenerationReconverges() async throws {
        try await withTestApp { app, _, project in
            try await self.subscribeToEverything(app: app)
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "cond-vm", project: project)
            let agentId = try await self.registerAgent(
                app: app, named: "cond-agent", capabilities: ["qemu"])
            vm.hypervisorId = agentId
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.generation = 5
            vm.observedGeneration = 5
            vm.lastError = "resize failed: no space left on device"
            vm.failedGeneration = 5
            // Cleared when the failure was recorded, which is what keeps the
            // recovery below from emitting a completion for a mutation whose
            // outcome the user was already told.
            vm.convergenceDeadline = nil
            try await vm.save(on: app.db)

            let recovered = try self.report(
                agentId: agentId,
                vms: [ObservedVMState(vmId: vm.id!, status: .running, observedGeneration: 5)]
            )
            await app.agentService.applyObservedStateReport(
                recovered, fromAgentKey: agentKey("cond-agent"))

            let refreshed = try #require(await VM.find(vm.id, on: app.db))
            #expect(refreshed.conditions.converged)
            #expect(refreshed.conditions.degraded == nil)
            #expect(try await self.mutationOutcomes(app: app) == [])
        }
    }
}
