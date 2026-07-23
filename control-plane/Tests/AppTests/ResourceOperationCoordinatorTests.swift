import Testing
import Vapor
import Fluent
import StratoShared

@testable import App

/// Fake `AgentDispatch` for driving the operation lifecycle through the
/// coordinator's own interface — no HTTP round-trip, no agent socket, no
/// `forTesting` back-doors. Records what the coordinator asked the agent to do.
private actor FakeAgentDispatch: AgentDispatch {
    var online: Bool
    var response: AgentServiceResponse
    private(set) var syncedAgentIds: [String] = []
    private(set) var awaitedResourceIds: [String] = []

    init(online: Bool = true, response: AgentServiceResponse = .success(nil)) {
        self.online = online
        self.response = response
    }

    func agentIsOnline(agentId: String) async -> Bool { online }

    func syncDesiredState(agentId: String) async { syncedAgentIds.append(agentId) }

    func performOperationAwaitingResponse(
        _ message: MessageType, resourceID: String, timeout: Duration
    ) async throws -> AgentServiceResponse {
        awaitedResourceIds.append(resourceID)
        return response
    }
}

/// Exercises `ResourceOperationCoordinator` directly: begin → dispatch (by
/// strategy) → verdict, with a fake agent seam and a template-clone database.
/// This is the seam the operation lifecycle previously lacked — the same logic
/// used to be `private static` on the controllers, reachable only through HTTP.
@Suite("Resource Operation Coordinator", .serialized)
final class ResourceOperationCoordinatorTests {
    /// Boots a configured test app with an org, project, and one VM. The
    /// operation's `userID` is a bare UUID — the row has no FK to a user.
    private func withVM(_ test: (Application, VM, UUID) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Coord Org")
            let project = try await builder.createProject(
                name: "Coord Project", description: "coordinator tests", organization: org)
            let vm = try await builder.createVM(name: "coord-vm", project: project)

            try await test(app, vm, UUID())
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    /// Boots a configured test app with an org, project, and one sandbox — for
    /// the `.sandbox` resource-kind path (its create-stuck signal differs).
    private func withSandbox(_ test: (Application, Sandbox, UUID) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Coord Org")
            let project = try await builder.createProject(
                name: "Coord Project", description: "coordinator tests", organization: org)
            let sandbox = try await builder.createSandbox(name: "coord-sbx", project: project)

            try await test(app, sandbox, UUID())
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("perform(.stateSync) on an online agent applies the mutation, nudges, and leaves the op pending")
    func stateSyncOnlineNudges() async throws {
        try await withVM { app, vm, userID in
            let fake = FakeAgentDispatch(online: true)
            let coordinator = ResourceOperationCoordinator(agentDispatch: fake, logger: app.logger)
            let vmID = try vm.requireID()

            let operation = try await coordinator.perform(
                .boot, resourceKind: .virtualMachine, resourceID: vmID, userID: userID,
                hypervisorId: "agent-1", dispatch: .stateSync, on: app.db, app: app
            ) { db in
                vm.setDesiredStatus(.running)
                try await vm.save(on: db)
            }
            #expect(operation.status == .pending)

            // The mutation committed atomically with the operation record.
            let reloadedVM = try await VM.find(vmID, on: app.db)
            let desired = reloadedVM?.desiredStatus
            #expect(desired == .running)

            await app.backgroundTasks.drain(timeout: .seconds(10))

            // The owning agent was nudged; the success verdict is deferred to the
            // observed-state applier, so the operation is still pending.
            let synced = await fake.syncedAgentIds
            #expect(synced == ["agent-1"])
            let opID = try operation.requireID()
            let reloadedOp = try await ResourceOperation.find(opID, on: app.db)
            let status = reloadedOp?.status
            #expect(status == .pending)
        }
    }

    @Test("perform(.stateSync) on an offline agent fails the operation")
    func stateSyncOfflineFails() async throws {
        try await withVM { app, vm, userID in
            let fake = FakeAgentDispatch(online: false)
            let coordinator = ResourceOperationCoordinator(agentDispatch: fake, logger: app.logger)
            let vmID = try vm.requireID()

            let operation = try await coordinator.perform(
                .boot, resourceKind: .virtualMachine, resourceID: vmID, userID: userID,
                hypervisorId: "agent-1", dispatch: .stateSync, on: app.db, app: app
            ) { db in
                vm.setDesiredStatus(.running)
                try await vm.save(on: db)
            }

            await app.backgroundTasks.drain(timeout: .seconds(10))

            let opID = try operation.requireID()
            let reloadedOp = try await ResourceOperation.find(opID, on: app.db)
            let status = reloadedOp?.status
            #expect(status == .failed)
            let error = reloadedOp?.error ?? ""
            #expect(error.contains("offline"))
            let synced = await fake.syncedAgentIds
            #expect(synced.isEmpty)
        }
    }

    @Test("perform(.stateSync) on an unplaced resource fails the operation")
    func stateSyncUnplacedFails() async throws {
        try await withVM { app, vm, userID in
            let fake = FakeAgentDispatch(online: true)
            let coordinator = ResourceOperationCoordinator(agentDispatch: fake, logger: app.logger)
            let vmID = try vm.requireID()

            let operation = try await coordinator.perform(
                .boot, resourceKind: .virtualMachine, resourceID: vmID, userID: userID,
                hypervisorId: nil, dispatch: .stateSync, on: app.db, app: app
            ) { db in
                vm.setDesiredStatus(.running)
                try await vm.save(on: db)
            }

            await app.backgroundTasks.drain(timeout: .seconds(10))

            let opID = try operation.requireID()
            let reloadedOp = try await ResourceOperation.find(opID, on: app.db)
            let status = reloadedOp?.status
            #expect(status == .failed)
            let error = reloadedOp?.error ?? ""
            #expect(error.contains("not placed"))
        }
    }

    @Test("a second operation for the same resource is rejected with 409")
    func doubleSubmitConflicts() async throws {
        try await withVM { app, vm, userID in
            let fake = FakeAgentDispatch(online: true)
            let coordinator = ResourceOperationCoordinator(agentDispatch: fake, logger: app.logger)
            let vmID = try vm.requireID()

            _ = try await coordinator.perform(
                .boot, resourceKind: .virtualMachine, resourceID: vmID, userID: userID,
                hypervisorId: "agent-1", dispatch: .stateSync, on: app.db, app: app
            ) { db in
                vm.setDesiredStatus(.running)
                try await vm.save(on: db)
            }

            var conflict: (any AbortError)?
            do {
                _ = try await coordinator.perform(
                    .shutdown, resourceKind: .virtualMachine, resourceID: vmID, userID: userID,
                    hypervisorId: "agent-1", dispatch: .stateSync, on: app.db, app: app
                ) { db in
                    vm.setDesiredStatus(.shutdown)
                    try await vm.save(on: db)
                }
            } catch let error as any AbortError {
                conflict = error
            }
            #expect(conflict?.status == .conflict)

            await app.backgroundTasks.drain(timeout: .seconds(10))
        }
    }

    @Test("perform(.awaitingResponse) records success from the agent response")
    func awaitingResponseSuccess() async throws {
        try await withVM { app, vm, userID in
            let fake = FakeAgentDispatch(online: true, response: .success(nil))
            let coordinator = ResourceOperationCoordinator(agentDispatch: fake, logger: app.logger)
            let vmID = try vm.requireID()

            let operation = try await coordinator.perform(
                .reboot, resourceKind: .virtualMachine, resourceID: vmID, userID: userID,
                hypervisorId: "agent-1", dispatch: .awaitingResponse(.vmReboot), on: app.db, app: app)

            await app.backgroundTasks.drain(timeout: .seconds(10))

            let opID = try operation.requireID()
            let reloadedOp = try await ResourceOperation.find(opID, on: app.db)
            let status = reloadedOp?.status
            #expect(status == .succeeded)
            let awaited = await fake.awaitedResourceIds
            #expect(awaited == [vmID.uuidString])
        }
    }

    @Test("perform(.awaitingResponse) records failure from an agent error")
    func awaitingResponseError() async throws {
        try await withVM { app, vm, userID in
            let fake = FakeAgentDispatch(online: true, response: .error("reboot exploded", nil))
            let coordinator = ResourceOperationCoordinator(agentDispatch: fake, logger: app.logger)
            let vmID = try vm.requireID()

            let operation = try await coordinator.perform(
                .reboot, resourceKind: .virtualMachine, resourceID: vmID, userID: userID,
                hypervisorId: "agent-1", dispatch: .awaitingResponse(.vmReboot), on: app.db, app: app)

            await app.backgroundTasks.drain(timeout: .seconds(10))

            let opID = try operation.requireID()
            let reloadedOp = try await ResourceOperation.find(opID, on: app.db)
            let status = reloadedOp?.status
            #expect(status == .failed)
            let error = reloadedOp?.error ?? ""
            #expect(error.contains("reboot exploded"))
        }
    }

    @Test("recordVerdict(.failed) on a create escalates a never-settled VM to .error")
    func recordVerdictResolvesCreateFailure() async throws {
        try await withVM { app, vm, userID in
            let coordinator = ResourceOperationCoordinator(
                agentDispatch: FakeAgentDispatch(), logger: app.logger)
            let vmID = try vm.requireID()
            vm.setStatus(.created)
            vm.setDesiredStatus(.shutdown)
            try await vm.save(on: app.db)

            let operation = try await ResourceOperation.begin(
                .create, resourceKind: .virtualMachine, resourceID: vmID, userID: userID, on: app.db)
            let opID = try operation.requireID()

            let won = await coordinator.recordVerdict(
                operationID: opID, as: .failed, error: "placement failed", on: app)
            #expect(won)

            let reloadedVM = try await VM.find(vmID, on: app.db)
            let status = reloadedVM?.status
            #expect(status == .error)
            let reloadedOp = try await ResourceOperation.find(opID, on: app.db)
            let opStatus = reloadedOp?.status
            #expect(opStatus == .failed)
        }
    }

    @Test("recordVerdict cannot overwrite an already-terminal operation")
    func recordVerdictLostRace() async throws {
        try await withVM { app, vm, userID in
            let coordinator = ResourceOperationCoordinator(
                agentDispatch: FakeAgentDispatch(), logger: app.logger)
            let vmID = try vm.requireID()

            let operation = try await ResourceOperation.begin(
                .boot, resourceKind: .virtualMachine, resourceID: vmID, userID: userID, on: app.db)
            let opID = try operation.requireID()

            let firstWon = await coordinator.recordVerdict(
                operationID: opID, as: .succeeded, error: nil, on: app)
            #expect(firstWon)
            let secondWon = await coordinator.recordVerdict(
                operationID: opID, as: .failed, error: "too late", on: app)
            #expect(!secondWon)

            let reloadedOp = try await ResourceOperation.find(opID, on: app.db)
            let status = reloadedOp?.status
            #expect(status == .succeeded)
        }
    }

    @Test("perform(.directResolution) removes the record and records success")
    func directResolutionDeletesRecord() async throws {
        try await withVM { app, vm, userID in
            let coordinator = ResourceOperationCoordinator(
                agentDispatch: FakeAgentDispatch(), logger: app.logger)
            let vmID = try vm.requireID()

            let operation = try await coordinator.perform(
                .delete, resourceKind: .virtualMachine, resourceID: vmID, userID: userID,
                hypervisorId: nil,
                dispatch: .directResolution { db in try await vm.delete(on: db) },
                on: app.db, app: app
            ) { db in
                vm.setDesiredStatus(.absent)
                try await vm.save(on: db)
            }

            await app.backgroundTasks.drain(timeout: .seconds(10))

            let opID = try operation.requireID()
            let reloadedOp = try await ResourceOperation.find(opID, on: app.db)
            let status = reloadedOp?.status
            #expect(status == .succeeded)
            let goneVM = try await VM.find(vmID, on: app.db)
            #expect(goneVM == nil)
        }
    }

    @Test("directResolution short-circuits when the operation is already terminal")
    func directResolutionGuardsResolvedOperation() async throws {
        try await withVM { app, vm, userID in
            let coordinator = ResourceOperationCoordinator(
                agentDispatch: FakeAgentDispatch(), logger: app.logger)
            let vmID = try vm.requireID()

            let operation = try await ResourceOperation.begin(
                .delete, resourceKind: .virtualMachine, resourceID: vmID, userID: userID, on: app.db)
            let opID = try operation.requireID()
            // The sweep already failed it.
            _ = await coordinator.recordVerdict(operationID: opID, as: .failed, error: "swept", on: app)

            coordinator.dispatch(
                operation, resourceKind: .virtualMachine, resourceID: vmID, hypervisorId: nil,
                dispatch: .directResolution { db in try await vm.delete(on: db) }, app: app)
            await app.backgroundTasks.drain(timeout: .seconds(10))

            // The removal work must not have run under a failed operation.
            let stillVM = try await VM.find(vmID, on: app.db)
            #expect(stillVM != nil)
            let reloadedOp = try await ResourceOperation.find(opID, on: app.db)
            let status = reloadedOp?.status
            #expect(status == .failed)
        }
    }

    @Test("recordVerdict(.failed) on a sandbox create escalates a never-confirmed sandbox to .error")
    func recordVerdictResolvesSandboxCreateFailure() async throws {
        try await withSandbox { app, sandbox, userID in
            let coordinator = ResourceOperationCoordinator(
                agentDispatch: FakeAgentDispatch(), logger: app.logger)
            let sandboxID = try sandbox.requireID()

            // A fresh sandbox has observedGeneration 0 — never confirmed by an
            // agent — which is the sandbox create-stuck signal.
            let operation = try await ResourceOperation.begin(
                .create, resourceKind: .sandbox, resourceID: sandboxID, userID: userID, on: app.db)
            let opID = try operation.requireID()

            let won = await coordinator.recordVerdict(
                operationID: opID, as: .failed, error: "placement failed", on: app)
            #expect(won)

            let reloaded = try await Sandbox.find(sandboxID, on: app.db)
            let status = reloaded?.status
            #expect(status == .error)
        }
    }
}
