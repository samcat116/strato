import Testing
import Vapor
import Fluent
import VaporTesting
import StratoShared
@testable import App

/// Tests for asynchronous VM operations (issue #259): mutation endpoints return
/// `202 Accepted` with an operation record, agent failures land on the operation
/// instead of vanishing, conflicting mutations are rejected with `409`, and the
/// stuck-operation sweep resolves operations that survive a process restart.
@Suite("VM Operation Tests", .serialized)
final class VMOperationTests {

    /// Boots a configured test app with a non-admin user, org, project and one VM.
    /// Mirrors the harness in `VMAuthorizationTests` so requests traverse the full
    /// middleware stack (role-binding-backed authorization, API-key auth).
    private func withVMTestApp(
        _ test: (Application, User, VM, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "vmopuser",
                email: "vmop@example.com",
                displayName: "VM Op User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "VM Op Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "VM Op Project",
                description: "Project for VM operation tests",
                organization: org
            )
            let vm = try await builder.createVM(name: "op-vm", project: project)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, vm, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// Waits for the background dispatch task to resolve the VM to `expected`.
    /// The operation is completed before the VM status is written, so once the
    /// VM matches, the operation is guaranteed terminal.
    private func pollVMStatus(
        _ vmID: UUID, until expected: VMStatus, on db: any Database
    ) async throws {
        for _ in 0..<100 {
            if let vm = try await VM.find(vmID, on: db), vm.status == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("VM \(vmID) never reached status \(expected.rawValue)")
    }

    /// Waits for the background dispatch task to complete the operation. The
    /// operation row and the VM row are written separately, so tests must poll
    /// the row they assert on — a VM-status poll does not order the operation
    /// write.
    private func pollOperationCompleted(
        _ operationId: UUID, on db: any Database
    ) async throws -> ResourceOperation? {
        for _ in 0..<100 {
            if let operation = try await ResourceOperation.find(operationId, on: db),
                operation.status != .pending
            {
                return operation
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Operation \(operationId) never completed")
        return nil
    }

    // MARK: - 202 + async failure recording

    @Test("POST /api/vms/:id/start returns 202 and records the dispatch failure on the operation")
    func startReturnsAcceptedAndFailsWithoutAgent() async throws {
        try await withVMTestApp { app, _, vm, token in
            var operationId: UUID?

            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.kind == .boot)
                #expect(operation.status == .pending)
                #expect(operation.vmId == vm.id)
                operationId = operation.id
            }

            // No agent is mapped to the VM, so the background dispatch fails
            // immediately: the operation must record it and the VM must be
            // restored to its pre-operation status (not left `.starting`).
            let operation = try await pollOperationCompleted(operationId!, on: app.db)
            #expect(operation?.status == .failed)
            #expect(operation?.error?.isEmpty == false)
            #expect(operation?.completedAt != nil)

            try await pollVMStatus(vm.id!, until: .created, on: app.db)
        }
    }

    // MARK: - Conflict guard

    @Test("A pending operation on the VM rejects a new mutation with 409")
    func conflictingPendingOperationRejected() async throws {
        try await withVMTestApp { app, user, vm, token in
            let pending = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .shutdown)
            try await pending.save(on: app.db)

            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // The rejected mutation must not have touched the VM.
            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .created)
        }
    }

    @Test("The partial unique index allows at most one pending operation per VM")
    func pendingUniquenessEnforcedByDatabase() async throws {
        try await withVMTestApp { app, user, vm, _ in
            // The database, not just the controller's read-then-insert check,
            // must reject a second pending operation — that is what closes the
            // race between two concurrent mutations.
            let first = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .boot)
            try await first.save(on: app.db)

            let second = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .shutdown)
            await #expect(throws: (any Error).self) {
                try await second.save(on: app.db)
            }

            // Terminal operations do not block new pending ones (the index is
            // partial on status = 'pending').
            _ = try await first.completeIfPending(as: .failed, error: "boom", on: app.db)
            let third = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .shutdown)
            try await third.save(on: app.db)
        }
    }

    // MARK: - Stuck-operation sweep (restart safety)

    @Test("The sweep fails a pending operation past its budget and resolves the VM")
    func sweepFailsStuckOperationAndResolvesVM() async throws {
        try await withVMTestApp { app, user, vm, _ in
            // Simulate a boot whose dispatching process died: pending operation,
            // VM stuck `.starting`, and no completion path left but the sweep.
            vm.setStatus(.starting, at: Date().addingTimeInterval(-400))
            try await vm.save(on: app.db)

            let operation = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .boot)
            try await operation.save(on: app.db)
            operation.createdAt = Date().addingTimeInterval(-400)  // past the 180s boot budget
            try await operation.save(on: app.db)

            await app.agentService.sweepStuckOperations()

            let swept = try await ResourceOperation.find(operation.id, on: app.db)
            #expect(swept?.status == .failed)
            #expect(swept?.error?.contains("timed out") == true)
            #expect(swept?.completedAt != nil)

            let sweptVM = try await VM.find(vm.id, on: app.db)
            #expect(sweptVM?.status == .error)
        }
    }

    @Test("The sweep fails a stuck create and marks the .created VM as error")
    func sweepFailsStuckCreate() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let operation = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .create)
            try await operation.save(on: app.db)
            operation.createdAt = Date().addingTimeInterval(-700)  // past the 600s create budget
            try await operation.save(on: app.db)

            await app.agentService.sweepStuckOperations()

            let swept = try await ResourceOperation.find(operation.id, on: app.db)
            #expect(swept?.status == .failed)

            // `.created` counts as stuck for a create operation specifically.
            let sweptVM = try await VM.find(vm.id, on: app.db)
            #expect(sweptVM?.status == .error)
        }
    }

    @Test("The sweep leaves fresh pending operations and their VMs alone")
    func sweepIgnoresFreshOperations() async throws {
        try await withVMTestApp { app, user, vm, _ in
            vm.setStatus(.starting)
            try await vm.save(on: app.db)

            let operation = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .boot)
            try await operation.save(on: app.db)

            await app.agentService.sweepStuckOperations()

            let fresh = try await ResourceOperation.find(operation.id, on: app.db)
            #expect(fresh?.status == .pending)

            let freshVM = try await VM.find(vm.id, on: app.db)
            #expect(freshVM?.status == .starting)
        }
    }

    // MARK: - Operation read API authorization

    @Test("GET /api/operations/:id follows the VM's read permission")
    func operationReadFollowsVMPermission() async throws {
        try await withVMTestApp { app, user, vm, token in
            let operation = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .boot)
            try await operation.save(on: app.db)

            try await app.test(.GET, "/api/operations/\(operation.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(OperationResponse.self)
                #expect(body.id == operation.id)
                #expect(body.vmId == vm.id)
            }

            // A user with no binding on the VM cannot read its operation.
            let outsider = try await TestDataBuilder(db: app.db).createUser(
                username: "op-outsider", email: "op-outsider@example.com")
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)
            try await app.test(.GET, "/api/operations/\(operation.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("An operation whose VM is gone is visible to its initiator only")
    func operationForDeletedVMVisibleToInitiatorOnly() async throws {
        try await withVMTestApp { app, user, vm, token in
            let operation = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .delete)
            operation.status = .succeeded
            try await operation.save(on: app.db)

            // Remove the VM row directly, as a completed delete would.
            try await vm.delete(on: app.db)

            try await app.test(.GET, "/api/operations/\(operation.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // A different (non-admin) user cannot see it — 404, not 403, so the
            // operation's existence is not leaked.
            let builder = TestDataBuilder(db: app.db)
            let other = try await builder.createUser(
                username: "othervmopuser",
                email: "othervmop@example.com",
                displayName: "Other User"
            )
            let otherToken = try await other.generateAPIKey(on: app.db)

            try await app.test(.GET, "/api/operations/\(operation.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: otherToken)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/vms/:id/operations lists newest first and honors limit")
    func listOperationsNewestFirst() async throws {
        try await withVMTestApp { app, user, vm, token in
            let older = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .boot)
            older.status = .succeeded
            try await older.save(on: app.db)
            older.createdAt = Date().addingTimeInterval(-60)
            try await older.save(on: app.db)

            let newer = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .shutdown)
            newer.status = .succeeded
            try await newer.save(on: app.db)

            try await app.test(.GET, "/api/vms/\(vm.id!)/operations?limit=1") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let operations = try res.content.decode([OperationResponse].self)
                #expect(operations.count == 1)
                #expect(operations.first?.id == newer.id)
            }
        }
    }
}
