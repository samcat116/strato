import Fluent
import StratoShared
import Testing
import Vapor

import AppTestSupport
@testable import App

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
                .create, resourceType: VM.self, resourceID: vmID, hypervisorId: nil,
                strategy: .placement { _ in
                    throw ResourceMutation.WorkError("no agent has capacity")
                }, app: app)

            await app.backgroundTasks.drain(timeout: .seconds(10))

            let reloaded = try #require(try await VM.find(vmID, on: app.db))
            #expect(reloaded.conditions.degraded?.reason.contains("no agent has capacity") == true)
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
}
