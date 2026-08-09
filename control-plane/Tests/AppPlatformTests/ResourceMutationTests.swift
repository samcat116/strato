import Fluent
import StratoShared
import Testing
import Vapor

import AppTestSupport
@testable import App

/// Fake `AgentDispatch` for driving a mutation through `ResourceMutation`'s own
/// interface — no HTTP round-trip, no agent socket, no `forTesting` back-doors.
/// Records what the mutation asked the agent to do.
///
/// Inherited from `ResourceOperationCoordinatorTests`, which went with the
/// coordinator in STR-152; it lost its `response` field at the same time,
/// because a dispatch has no reply to canned any more.
actor FakeAgentDispatch: AgentDispatch {
    var online: Bool
    private(set) var syncedAgentIds: [String] = []

    init(online: Bool = true) {
        self.online = online
    }

    func agentIsOnline(agentId: String) async -> Bool { online }

    func syncDesiredState(agentId: String) async { syncedAgentIds.append(agentId) }
}

actor DispatchFailureGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// `ResourceMutation` — the accept path that replaced the operation row for
/// generation-backed lifecycle mutations (ADR 0001 stage 4, STR-147).
///
/// Covers what the coordinator's state-sync / placement / direct-resolution
/// tests used to, restated against the resource's own `conditions`, plus the
/// two things that are new: the convergence deadline's `max` composition, and
/// the absence of the "operation already pending" mutex.
@Suite("Resource Mutation", .serialized)
final class ResourceMutationTests {
    private func withVM(_ test: (Application, VM) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Mutation Org")
            let project = try await builder.createProject(
                name: "Mutation Project", description: "mutation tests", organization: org)
            let vm = try await builder.createVM(name: "mutation-vm", project: project)

            try await test(app, vm)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func withSandbox(_ test: (Application, Sandbox) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Mutation Org")
            let project = try await builder.createProject(
                name: "Mutation Project", description: "mutation tests", organization: org)
            let sandbox = try await builder.createSandbox(
                name: "mutation-sandbox", project: project)

            try await test(app, sandbox)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func mutation(_ app: Application, _ fake: FakeAgentDispatch) -> ResourceMutation {
        ResourceMutation(agentDispatch: fake, logger: app.logger)
    }

    // MARK: - Dispatch

    @Test("accept(.stateSync) on an online agent applies the mutation, nudges, and stays unconverged")
    func stateSyncOnlineNudges() async throws {
        try await withVM { app, vm in
            let fake = FakeAgentDispatch(online: true)
            vm.hypervisorId = "agent-1"
            try await vm.save(on: app.db)
            let vmID = try vm.requireID()

            let accepted = try await self.mutation(app, fake).accept(
                .boot, on: vm, actor: .user(UUID()), dispatch: .stateSync, on: app.db, app: app
            ) { _ in vm.setDesiredStatus(.running) }

            // The mutation committed atomically with the attribution event, and
            // the client is told which generation to wait for.
            let reloaded = try #require(try await VM.find(vmID, on: app.db))
            #expect(reloaded.desiredStatus == .running)
            #expect(accepted.targetGeneration == reloaded.generation)
            let event = try #require(try await ResourceEvent.find(accepted.mutationID, on: app.db))
            #expect(event.mutation == .boot)
            #expect(event.phase == .requested)

            await app.backgroundTasks.drain(timeout: .seconds(10))

            // The owning agent was nudged; nothing is converged until it reports.
            let synced = await fake.syncedAgentIds
            #expect(synced == ["agent-1"])
            let afterDispatch = try #require(try await VM.find(vmID, on: app.db))
            #expect(!afterDispatch.conditions.converged)
            #expect(afterDispatch.conditions.degraded == nil)
        }
    }

    @Test("accept(.stateSync) on an offline agent degrades the resource")
    func stateSyncOfflineDegrades() async throws {
        try await withVM { app, vm in
            let fake = FakeAgentDispatch(online: false)
            vm.hypervisorId = "agent-1"
            try await vm.save(on: app.db)
            let vmID = try vm.requireID()

            let accepted = try await self.mutation(app, fake).accept(
                .boot, on: vm, actor: .user(UUID()), dispatch: .stateSync, on: app.db, app: app
            ) { _ in vm.setDesiredStatus(.running) }

            await app.backgroundTasks.drain(timeout: .seconds(10))

            let reloaded = try #require(try await VM.find(vmID, on: app.db))
            let degraded = try #require(reloaded.conditions.degraded)
            #expect(degraded.reason.contains("offline"))
            #expect(degraded.sinceGeneration == accepted.targetGeneration)
            // A failure clears the deadline: there is nothing left to time out.
            #expect(reloaded.convergenceDeadline == nil)
            let synced = await fake.syncedAgentIds
            #expect(synced.isEmpty)
        }
    }

    @Test("accept(.stateSync) on an unplaced resource degrades the resource")
    func stateSyncUnplacedDegrades() async throws {
        try await withVM { app, vm in
            let fake = FakeAgentDispatch(online: true)
            let vmID = try vm.requireID()

            _ = try await self.mutation(app, fake).accept(
                .boot, on: vm, actor: .user(UUID()), dispatch: .stateSync, on: app.db, app: app
            ) { _ in vm.setDesiredStatus(.running) }

            await app.backgroundTasks.drain(timeout: .seconds(10))

            let reloaded = try #require(try await VM.find(vmID, on: app.db))
            #expect(reloaded.conditions.degraded?.reason.contains("not placed") == true)
        }
    }

    @Test("accept(.placement) degrades the resource when the placement work throws")
    func placementFailureDegrades() async throws {
        try await withVM { app, vm in
            let fake = FakeAgentDispatch(online: true)
            let vmID = try vm.requireID()

            self.mutation(app, fake).dispatch(
                .create, resourceType: VM.self, resourceID: vmID,
                targetGeneration: vm.generation, hypervisorId: nil,
                strategy: .placement { _ in
                    throw ResourceMutation.WorkError("no agent has capacity")
                }, app: app)

            await app.backgroundTasks.drain(timeout: .seconds(10))

            let reloaded = try #require(try await VM.find(vmID, on: app.db))
            #expect(reloaded.conditions.degraded?.reason.contains("no agent has capacity") == true)
        }
    }

    @Test("a dispatch failure cannot degrade a newer desired state")
    func supersededDispatchFailureIsDropped() async throws {
        try await withVM { app, vm in
            let fake = FakeAgentDispatch(online: true)
            let gate = DispatchFailureGate()
            let vmID = try vm.requireID()

            // Hold the create-generation placement until a newer lifecycle
            // mutation commits. Its eventual failure belongs only to the old
            // target and must not clear the new target's deadline or emit an
            // obsolete failure outcome.
            self.mutation(app, fake).dispatch(
                .create, resourceType: VM.self, resourceID: vmID,
                targetGeneration: vm.generation, hypervisorId: nil,
                strategy: .placement { _ in
                    await gate.wait()
                    throw ResourceMutation.WorkError("obsolete placement failed")
                }, app: app)
            await gate.waitUntilEntered()

            let accepted = try await self.mutation(app, fake).accept(
                .boot, on: vm, actor: .user(UUID()),
                dispatch: .directResolution { _ in false },
                on: app.db, app: app
            ) { _ in
                vm.setDesiredStatus(.running)
            }
            await gate.release()
            await app.backgroundTasks.drain(timeout: .seconds(10))

            let reloaded = try #require(try await VM.find(vmID, on: app.db))
            #expect(reloaded.generation == accepted.targetGeneration)
            #expect(reloaded.desiredStatus == .running)
            #expect(reloaded.convergenceDeadline != nil)
            #expect(reloaded.lastError == nil)
            #expect(reloaded.failedGeneration == nil)
        }
    }

    @Test("accept(.directResolution) removes the record")
    func directResolutionDeletesRecord() async throws {
        try await withVM { app, vm in
            let fake = FakeAgentDispatch(online: true)
            let vmID = try vm.requireID()

            _ = try await self.mutation(app, fake).accept(
                .delete, on: vm, actor: .user(UUID()),
                dispatch: .directResolution { db in
                    ResourceFinalizerService.stampForDeletion(vm)
                    return try await ResourceFinalizerService.clear(
                        .agentAbsent, from: vm, on: db, app: app
                    ).isRemoved
                },
                on: app.db, app: app
            ) { _ in
                ResourceFinalizerService.stampForDeletion(vm)
                vm.setDesiredStatus(.absent)
            }

            await app.backgroundTasks.drain(timeout: .seconds(10))

            #expect(try await VM.find(vmID, on: app.db) == nil)
        }
    }

    // MARK: - Convergence deadline

    @Test("a short-budget mutation never shortens a long one's deadline")
    func deadlineTakesTheMaximum() async throws {
        // The review finding this design answers: with the "operation already
        // pending" mutex dropped, a reboot issued while a 600s create is still
        // downloading its image would — under a last-writer-wins
        // `lastMutationKind` — judge the create against reboot's 120s budget
        // and flip a healthy VM to degraded.
        try await withVM { app, vm in
            let fake = FakeAgentDispatch(online: true)
            vm.hypervisorId = "agent-1"

            // Committed, as the create transaction leaves it — `accept`
            // refreshes the reconciliation-owned columns under its row lock, so
            // an unsaved deadline is not what the reboot composes against.
            vm.extendConvergenceDeadline(
                by: OperationResourceKind.virtualMachine.completionBudgetSeconds(for: .create))
            try await vm.save(on: app.db)
            let createDeadline = try #require(vm.convergenceDeadline)

            _ = try await self.mutation(app, fake).accept(
                .reboot, on: vm, actor: .user(UUID()), dispatch: .stateSync, on: app.db, app: app
            ) { _ in vm.setDesiredStatus(.running) }

            let reloaded = try #require(try await VM.find(try vm.requireID(), on: app.db))
            let deadline = try #require(reloaded.convergenceDeadline)
            // Reboot's 120s is well inside create's 600s, so the deadline is
            // unchanged rather than pulled in.
            #expect(abs(deadline.timeIntervalSince(createDeadline)) < 1)

            await app.backgroundTasks.drain(timeout: .seconds(10))
        }
    }

    @Test("a longer budget pushes the deadline out")
    func deadlineExtendsForward() async throws {
        try await withVM { app, vm in
            vm.extendConvergenceDeadline(by: 120)
            let short = try #require(vm.convergenceDeadline)
            vm.extendConvergenceDeadline(by: 600)
            let long = try #require(vm.convergenceDeadline)
            #expect(long > short)
        }
    }

    // MARK: - The dropped mutex

    @Test("a mutation cannot write a stale snapshot back over the observed state")
    func acceptRefreshesReconciliationState() async throws {
        try await withVM { app, vm in
            let fake = FakeAgentDispatch(online: true)
            let vmID = try vm.requireID()

            // The route handler's instance is loaded, and *then* the agent's
            // report commits — the window every converted endpoint has, since
            // it mutates a model read before the request's transaction opened.
            let staleFromTheRouteHandler = try #require(try await VM.find(vmID, on: app.db))
            let reported = try #require(try await VM.find(vmID, on: app.db))
            reported.hypervisorId = "agent-1"
            reported.observedGeneration = 7
            reported.generation = 7
            reported.setStatus(.running)
            try await reported.save(on: app.db)

            _ = try await self.mutation(app, fake).accept(
                .shutdown, on: staleFromTheRouteHandler, actor: .user(UUID()),
                dispatch: .stateSync, on: app.db, app: app
            ) { _ in staleFromTheRouteHandler.setDesiredStatus(.shutdown) }

            let reloaded = try #require(try await VM.find(vmID, on: app.db))
            // None of this may regress: an observedGeneration going backwards
            // un-converges a client that was already satisfied, and a nulled
            // hypervisorId loses the scheduler's placement.
            #expect(reloaded.observedGeneration == 7)
            #expect(reloaded.status == .running)
            #expect(reloaded.hypervisorId == "agent-1")
            // And the mutation itself still applied, on top of the newer
            // generation rather than under it.
            #expect(reloaded.desiredStatus == .shutdown)
            #expect(reloaded.generation == 8)

            await app.backgroundTasks.drain(timeout: .seconds(10))
        }
    }

    @Test("overlapping lifecycle mutations are accepted; the last one wins")
    func overlappingMutationsAreAccepted() async throws {
        try await withVM { app, vm in
            let fake = FakeAgentDispatch(online: true)
            vm.hypervisorId = "agent-1"
            try await vm.save(on: app.db)
            let vmID = try vm.requireID()

            let start = try await self.mutation(app, fake).accept(
                .boot, on: vm, actor: .user(UUID()), dispatch: .stateSync, on: app.db, app: app
            ) { _ in vm.setDesiredStatus(.running) }

            // No 409: level-triggered desired state makes the overlap safe, and
            // "stop it, it's taking too long" is exactly what a user does.
            let stop = try await self.mutation(app, fake).accept(
                .shutdown, on: vm, actor: .user(UUID()), dispatch: .stateSync, on: app.db, app: app
            ) { _ in vm.setDesiredStatus(.shutdown) }

            #expect(stop.targetGeneration > start.targetGeneration)
            let reloaded = try #require(try await VM.find(vmID, on: app.db))
            #expect(reloaded.desiredStatus == .shutdown)

            await app.backgroundTasks.drain(timeout: .seconds(10))
        }
    }

    @Test("concurrent lifecycle mutations receive distinct consecutive generations")
    func concurrentMutationsReceiveDistinctGenerations() async throws {
        try await withVM { app, vm in
            let fake = FakeAgentDispatch(online: true)
            vm.hypervisorId = "agent-1"
            try await vm.save(on: app.db)
            let vmID = try vm.requireID()
            let firstSnapshot = try #require(try await VM.find(vmID, on: app.db))
            let secondSnapshot = try #require(try await VM.find(vmID, on: app.db))
            let runningMutation = self.mutation(app, fake)
            let shutdownMutation = self.mutation(app, fake)

            async let running = runningMutation.accept(
                .boot, on: firstSnapshot, actor: .user(UUID()), dispatch: .stateSync,
                on: app.db, app: app
            ) { _ in
                firstSnapshot.setDesiredStatus(.running)
            }
            async let shutdown = shutdownMutation.accept(
                .shutdown, on: secondSnapshot, actor: .user(UUID()), dispatch: .stateSync,
                on: app.db, app: app
            ) { _ in
                secondSnapshot.setDesiredStatus(.shutdown)
            }

            let (runningAccepted, shutdownAccepted) = try await (running, shutdown)
            #expect(
                Set([runningAccepted.targetGeneration, shutdownAccepted.targetGeneration])
                    == [1, 2])

            let reloaded = try #require(try await VM.find(vmID, on: app.db))
            let expectedDesired: DesiredVMStatus =
                runningAccepted.targetGeneration > shutdownAccepted.targetGeneration
                ? .running : .shutdown
            #expect(reloaded.generation == 2)
            #expect(reloaded.desiredStatus == expectedDesired)

            await app.backgroundTasks.drain(timeout: .seconds(10))
        }
    }

    @Test("a stale failure cannot overwrite a newer deletion intent")
    func staleFailureCannotOverwriteDelete() async throws {
        try await withVM { app, vm in
            let fake = FakeAgentDispatch(online: true)
            let vmID = try vm.requireID()
            vm.generation = 10
            vm.desiredStatus = .running
            vm.setStatus(.starting)
            vm.convergenceDeadline = Date().addingTimeInterval(120)
            try await vm.save(on: app.db)

            // This is the applier's bulk-loaded copy. A delete commits after
            // it was read but before its failed-generation resolution saves.
            let staleReportCopy = try #require(try await VM.find(vmID, on: app.db))
            let deleteCopy = try #require(try await VM.find(vmID, on: app.db))
            let acceptedDelete = try await self.mutation(app, fake).accept(
                .delete, on: deleteCopy, actor: .user(UUID()),
                dispatch: .directResolution { _ in false },
                on: app.db, app: app
            ) { _ in
                ResourceFinalizerService.stampForDeletion(deleteCopy)
                deleteCopy.setDesiredStatus(.absent)
            }
            #expect(acceptedDelete.targetGeneration == 11)

            staleReportCopy.setStatus(.shutdown)
            let outcome = try await ResourceConvergence.recordFailure(
                staleReportCopy,
                mutation: .boot,
                reason: "boot failed before the delete",
                telemetryReason: "convergence_failed",
                on: app.db)
            #expect(outcome == .superseded(actualGeneration: 11))

            let reloaded = try #require(try await VM.find(vmID, on: app.db))
            #expect(reloaded.generation == 11)
            #expect(reloaded.desiredStatus == .absent)
            #expect(reloaded.lastError == nil)
            #expect(reloaded.failedGeneration == nil)

            await app.backgroundTasks.drain(timeout: .seconds(10))
        }
    }

    @Test("a stale sandbox failure cannot overwrite a newer deletion intent")
    func staleSandboxFailureCannotOverwriteDelete() async throws {
        try await withSandbox { app, sandbox in
            let fake = FakeAgentDispatch(online: true)
            let sandboxID = try sandbox.requireID()
            sandbox.generation = 10
            sandbox.desiredStatus = .running
            sandbox.setStatus(.starting)
            sandbox.convergenceDeadline = Date().addingTimeInterval(120)
            try await sandbox.save(on: app.db)

            let staleReportCopy = try #require(try await Sandbox.find(sandboxID, on: app.db))
            let deleteCopy = try #require(try await Sandbox.find(sandboxID, on: app.db))
            let acceptedDelete = try await self.mutation(app, fake).accept(
                .delete, on: deleteCopy, actor: .user(UUID()),
                dispatch: .directResolution { _ in false },
                on: app.db, app: app
            ) { _ in
                ResourceFinalizerService.stampForDeletion(deleteCopy)
                deleteCopy.setDesiredStatus(.absent)
            }
            #expect(acceptedDelete.targetGeneration == 11)

            staleReportCopy.setStatus(.stopped)
            let outcome = try await ResourceConvergence.recordFailure(
                staleReportCopy,
                mutation: .boot,
                reason: "start failed before the delete",
                telemetryReason: "convergence_failed",
                on: app.db)
            #expect(outcome == .superseded(actualGeneration: 11))

            let reloaded = try #require(try await Sandbox.find(sandboxID, on: app.db))
            #expect(reloaded.generation == 11)
            #expect(reloaded.desiredStatus == .absent)
            #expect(reloaded.lastError == nil)
            #expect(reloaded.failedGeneration == nil)

            await app.backgroundTasks.drain(timeout: .seconds(10))
        }
    }

    // MARK: - Failures that leave nothing to abandon (STR-191)

    /// The state the ambiguity lived in, and which nothing else constructs.
    ///
    /// Every other `recordFailure` path goes through a `resolveForStuckOperation`
    /// that advances the generation, so `failedGeneration` ends one *behind*
    /// `generation` and the two conditions cannot collide. A VM already sitting
    /// at its desired status has nothing to abandon — `revertDesiredToObserved`
    /// returns false — so the failure stays pinned to the current generation
    /// until a new mutation moves the target.
    @Test("a failure with nothing to revert stays pinned to the current generation")
    func failureWithNothingToRevertPins() async throws {
        try await withVM { app, vm in
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.observedGeneration = vm.generation
            try await vm.save(on: app.db)
            let generation = vm.generation

            let recorded = try await ResourceConvergence.recordFailure(
                vm, mutation: .resize, reason: "resize failed: no space left on device",
                telemetryReason: "convergence_failed", on: app.db)
            #expect(recorded == .recorded)
            #expect(vm.generation == generation)  // nothing was abandoned
            #expect(vm.failedGeneration == generation)
            #expect(!vm.conditions.converged)
            #expect(vm.conditions.degraded?.sinceGeneration == generation)

            // Idempotent: the agent restates the same error on every heartbeat.
            let again = try await ResourceConvergence.recordFailure(
                vm, mutation: .resize, reason: "resize failed: no space left on device",
                telemetryReason: "convergence_failed", on: app.db)
            #expect(again == .alreadyRecorded)

            await app.backgroundTasks.drain(timeout: .seconds(10))
        }
    }

    /// The user's escape hatch from the state above: any new mutation moves the
    /// target past the failure, so `converged` is decided by the generation
    /// clause again and the stale `degraded` reads as superseded.
    @Test("a new mutation moves the target past a pinned failure")
    func newMutationClearsTheAmbiguity() async throws {
        try await withVM { app, vm in
            let fake = FakeAgentDispatch(online: true)
            vm.hypervisorId = "agent-1"
            vm.setFixtureDesiredStatus(.running)
            vm.setStatus(.running)
            vm.observedGeneration = vm.generation
            vm.lastError = "resize failed: no space left on device"
            vm.failedGeneration = vm.generation
            try await vm.save(on: app.db)
            let vmID = try vm.requireID()
            let failedAt = vm.generation

            let accepted = try await self.mutation(app, fake).accept(
                .shutdown, on: vm, actor: .user(UUID()), dispatch: .stateSync, on: app.db, app: app
            ) { _ in vm.setDesiredStatus(.shutdown) }
            #expect(accepted.targetGeneration > failedAt)

            var reloaded = try #require(try await VM.find(vmID, on: app.db))
            // Not converged, but on the generation clause now — the failure is
            // one a newer mutation is already retrying past.
            #expect(!reloaded.conditions.converged)
            #expect(reloaded.conditions.degraded?.sinceGeneration == failedAt)

            reloaded.setStatus(.shutdown)
            reloaded.observedGeneration = reloaded.generation
            reloaded.lastError = nil
            reloaded.failedGeneration = nil
            try await reloaded.save(on: app.db)

            reloaded = try #require(try await VM.find(vmID, on: app.db))
            #expect(reloaded.conditions.converged)
            #expect(reloaded.conditions.degraded == nil)

            await app.backgroundTasks.drain(timeout: .seconds(10))
        }
    }
}
