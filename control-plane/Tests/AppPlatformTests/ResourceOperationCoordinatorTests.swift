import Testing
import Vapor
import Fluent
import StratoShared

import AppTestSupport
@testable import App

/// Fake `AgentDispatch` for driving the operation lifecycle through the
/// coordinator's own interface — no HTTP round-trip, no agent socket, no
/// `forTesting` back-doors. Records what the coordinator asked the agent to do.
actor FakeAgentDispatch: AgentDispatch {
    var online: Bool
    var response: AgentServiceResponse
    private(set) var syncedAgentIds: [String] = []

    init(online: Bool = true, response: AgentServiceResponse = .success(nil)) {
        self.online = online
        self.response = response
    }

    func agentIsOnline(agentId: String) async -> Bool { online }

    func syncDesiredState(agentId: String) async { syncedAgentIds.append(agentId) }
}

/// Exercises what is left of `ResourceOperationCoordinator`: the verdict choke
/// point, against a template-clone database.
///
/// Its remit shrank to nothing over three stages. STR-147 moved the state-sync,
/// placement and direct-resolution strategies to `ResourceMutation` (covered by
/// `ResourceMutationTests`), STR-150 took the snapshot verbs, and STR-151 took
/// the last one — VM reboot, whose `awaitingResponse` dispatch was the only
/// imperative strategy left. Nothing constructs a `ResourceOperation` now.
///
/// These tests survive for the reason `recordVerdict` does: rows written by the
/// *previous* build can still be `pending` after an upgrade, and the sweep has
/// to take them terminal rather than leave a client polling forever. They go
/// with the table in ADR stage 11 (STR-152).
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
