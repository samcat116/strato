import Testing
import Vapor
import Fluent
import SQLKit
import VaporTesting
import StratoShared
import AppTestSupport
@testable import App

/// Tests for asynchronous VM operations (issue #259), as ADR 0001 stage 4
/// left them (STR-147): lifecycle mutations return `202 Accepted` with
/// `{resource, targetGeneration, mutationId}` and are judged by the VM's own
/// `conditions`, the operations API keeps answering for them as a façade, and
/// the stuck-operation sweep still covers the imperative verbs that kept their
/// rows.
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

    /// Waits for the background dispatch to degrade the VM, returning its
    /// `conditions`. The `202` returns before the dispatch runs, so a test
    /// asserting on the outcome has to poll the row it asserts on.
    private func pollDegraded(_ vmID: UUID, on db: any Database) async throws -> ResourceConditions? {
        for _ in 0..<100 {
            if let vm = try await VM.find(vmID, on: db), vm.conditions.degraded != nil {
                return vm.conditions
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("VM \(vmID) never went degraded")
        return nil
    }

    // MARK: - 202 + async failure recording

    @Test("POST /api/vms/:id/start returns 202 with the VM and its target generation")
    func startReturnsAcceptedAndDegradesWithoutAgent() async throws {
        try await withVMTestApp { app, _, vm, token in
            var accepted: AcceptedMutation<VMDetailResponse>?

            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                let body = try res.content.decode(AcceptedMutation<VMDetailResponse>.self)
                #expect(body.resource.id == vm.id)
                // The generation the client waits for is the one the mutation
                // just wrote, and the VM has not reached it yet.
                #expect(body.targetGeneration == body.resource.conditions.targetGeneration)
                #expect(!body.resource.conditions.converged)
                accepted = body
            }
            let body = try #require(accepted)

            // No agent is mapped to the VM, so the background dispatch fails
            // immediately: the VM must go degraded at this generation and be
            // restored to its pre-mutation status (not left `.starting`).
            let conditions = try await pollDegraded(vm.id!, on: app.db)
            #expect(conditions?.degraded?.sinceGeneration == body.targetGeneration)
            #expect(conditions?.degraded?.reason.isEmpty == false)

            try await pollVMStatus(vm.id!, until: .created, on: app.db)

            // And the operations façade reports the same thing to a client that
            // still polls the old way.
            try await app.test(.GET, "/api/operations/\(body.mutationId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.kind == .boot)
                #expect(operation.status == .failed)
                #expect(operation.vmId == vm.id)
                #expect(operation.error?.isEmpty == false)
            }
        }
    }

    // MARK: - Delete cleans up IAM bindings (STR-112)

    @Test("DELETE takes the VM's role bindings — and its checkpoints' — with the row")
    func deleteRevokesRoleBindings() async throws {
        try await withVMTestApp { app, user, vm, token in
            let vmID = try vm.requireID()

            // The creator binding VM creation writes, plus a checkpoint whose
            // row cascades away with the VM and so orphans its binding too.
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .virtualMachine, nodeID: vmID, createdBy: user.id!, on: app.db)
            let snapshot = VMSnapshot(
                name: "checkpoint", vmID: vmID, projectID: vm.$project.id,
                environment: vm.environment, agentId: nil, createdByID: user.id!)
            try await snapshot.save(on: app.db)
            let snapshotID = try snapshot.requireID()
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .vmSnapshot, nodeID: snapshotID, createdBy: user.id!, on: app.db)

            // Unplaced VM, so the delete resolves directly instead of waiting
            // for an agent to confirm absence.
            var mutationId: UUID?
            try await app.test(.DELETE, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                mutationId = try res.content.decode(AcceptedMutation<VMDetailResponse>.self).mutationId
            }

            try await self.pollVMRemoved(vmID, on: app.db)
            let gone = try await VM.find(vmID, on: app.db)
            #expect(gone == nil)

            // The delete's completion signal: the reap appended a terminal
            // event, and the façade answers `succeeded` off it — the one thing
            // `conditions` cannot say, because the resource is gone.
            try await app.test(.GET, "/api/operations/\(mutationId!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.kind == .delete)
                #expect(operation.status == .succeeded)
                #expect(operation.completedAt != nil)
            }

            let vmBindings = try await RoleBinding.query(on: app.db)
                .filter(\.$nodeType == IAMNodeType.virtualMachine.rawValue)
                .filter(\.$nodeID == vmID)
                .count()
            #expect(vmBindings == 0)
            let snapshotBindings = try await RoleBinding.query(on: app.db)
                .filter(\.$nodeType == IAMNodeType.vmSnapshot.rawValue)
                .filter(\.$nodeID == snapshotID)
                .count()
            #expect(snapshotBindings == 0)
        }
    }

    /// Waits for the background dispatch to reap the deleted row.
    private func pollVMRemoved(_ vmID: UUID, on db: any Database) async throws {
        for _ in 0..<100 {
            if try await VM.find(vmID, on: db) == nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("VM \(vmID) was never removed")
    }

    // MARK: - The dropped mutex

    @Test("A pending snapshot operation no longer blocks a lifecycle mutation")
    func pendingOperationDoesNotBlockLifecycleMutation() async throws {
        try await withVMTestApp { app, user, vm, token in
            // A checkpoint in flight: still an operation row, because it is an
            // imperative agent RPC with no generation to converge on.
            let pending = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .snapshot)
            try await pending.save(on: app.db)

            // Starting the VM is a level-triggered desired-state write, so it
            // is accepted rather than refused with the `409` the operation
            // mutex used to produce (STR-147).
            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            // The boot was recorded and bumped a generation of its own; what
            // the background dispatch then does with an unplaced VM is the
            // subject of `startReturnsAcceptedAndDegradesWithoutAgent`.
            let boot = try await ResourceEvent.latest(
                .requested, resourceKind: .virtualMachine, resourceID: vm.id!, on: app.db)
            #expect(boot?.mutation == .boot)
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

    // MARK: - Completion guard (only one verdict per operation)

    @Test("A stale pending instance cannot overwrite a recorded verdict")
    func staleInstanceCannotOverwriteVerdict() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let operation = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .boot)
            try await operation.save(on: app.db)

            // The two completion paths — the observed-state applier and the
            // stuck-operation sweep — each load their own instance while the row
            // is still pending. Whichever writes second is holding a stale
            // in-memory `pending`, so only a database-side check can stop it.
            let applierView = try #require(try await ResourceOperation.find(operation.id, on: app.db))
            let sweepView = try #require(try await ResourceOperation.find(operation.id, on: app.db))

            let applierWon = try await applierView.completeIfPending(as: .succeeded, error: nil, on: app.db)
            #expect(applierWon)

            #expect(sweepView.status == .pending)
            let sweepWon = try await sweepView.completeIfPending(as: .failed, error: "timed out", on: app.db)
            #expect(!sweepWon)

            // The winner's verdict stands; the loser wrote nothing.
            let settled = try #require(try await ResourceOperation.find(operation.id, on: app.db))
            #expect(settled.status == .succeeded)
            #expect(settled.error == nil)
        }
    }

    @Test("Two concurrent completions with opposite verdicts: exactly one wins")
    func concurrentCompletionsSettleOnOneVerdict() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let operation = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .reboot)
            try await operation.save(on: app.db)
            let operationID = try operation.requireID()

            let verdicts: [(status: VMOperationStatus, error: String?)] = [
                (.succeeded, nil), (.failed, "timed out"),
            ]
            let wins = try await withThrowingTaskGroup(of: Bool.self) { group in
                for verdict in verdicts {
                    group.addTask {
                        guard let view = try await ResourceOperation.find(operationID, on: app.db) else {
                            return false
                        }
                        return try await view.completeIfPending(
                            as: verdict.status, error: verdict.error, on: app.db)
                    }
                }
                var results: [Bool] = []
                for try await won in group { results.append(won) }
                return results
            }

            #expect(wins.count(where: { $0 }) == 1)
            #expect(wins.count(where: { !$0 }) == 1)

            // The row settled on one of the two verdicts, consistently — a
            // `.failed` row must carry its error and a `.succeeded` one must not.
            let settled = try #require(try await ResourceOperation.find(operationID, on: app.db))
            #expect(settled.status != .pending)
            #expect(settled.completedAt != nil)
            #expect((settled.status == .failed) == (settled.error != nil))
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

    @Test("A transitional VM past the timeout is left alone while an operation is still pending")
    func sweepLeavesTransitionalVMWithPendingOperationAlone() async throws {
        try await withVMTestApp { app, user, vm, _ in
            // Old enough for the transitional backstop (120s) but with a fresh
            // operation still inside its own budget: the pending operation owns
            // this VM's resolution, so the backstop must skip it. Without the
            // backdating, `sweepIgnoresFreshOperations` never reaches the guard
            // — the VM is filtered out in SQL by the age predicate first.
            vm.setStatus(.starting, at: Date().addingTimeInterval(-400))
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

    @Test("A transitional VM with no status timestamp is aged off updatedAt")
    func sweepAgesTransitionalVMOffUpdatedAtWhenStatusTimestampIsMissing() async throws {
        try await withVMTestApp { app, _, vm, _ in
            vm.setStatus(.starting)
            try await vm.save(on: app.db)

            // Rows written before `status_changed_at` existed carry NULL. The
            // sweep's age predicate is evaluated in SQL now, so this fallback
            // branch is the one that could silently stop matching.
            let vmID = try vm.requireID()
            let sql = try #require(app.db as? any SQLDatabase)
            let past = Date().addingTimeInterval(-400)
            try await sql.raw(
                """
                UPDATE vms SET status_changed_at = NULL, updated_at = \(bind: past)
                WHERE id = \(bind: vmID)
                """
            ).run()

            await app.agentService.sweepStuckOperations()

            let swept = try await VM.find(vm.id, on: app.db)
            #expect(swept?.status == .error)
        }
    }

    @Test("A transitional VM with no timestamps at all is left alone")
    func sweepLeavesTimestamplessTransitionalVMAlone() async throws {
        try await withVMTestApp { app, _, vm, _ in
            vm.setStatus(.starting)
            try await vm.save(on: app.db)

            // No measurable age: the sweep has no evidence the VM is stuck, so
            // it must not be errored on the strength of a NULL.
            let vmID = try vm.requireID()
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw(
                """
                UPDATE vms SET status_changed_at = NULL, updated_at = NULL
                WHERE id = \(bind: vmID)
                """
            ).run()

            await app.agentService.sweepStuckOperations()

            let swept = try await VM.find(vm.id, on: app.db)
            #expect(swept?.status == .starting)
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

            // A malformed limit is a 400 here too, not a silent fall back to
            // the default — every int query parameter goes through the same
            // shared parse (issue #732).
            try await app.test(.GET, "/api/vms/\(vm.id!)/operations?limit=abc") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - The operations façade (STR-147)

    /// Records a mutation the way `ResourceMutation` does, without the dispatch.
    private func record(
        _ kind: VMOperationKind, on vm: VM, by user: User, on db: any Database
    ) async throws -> ResourceEvent {
        try await ResourceEvent.record(
            kind, resourceKind: .virtualMachine, resourceID: try vm.requireID(),
            actor: .user(try user.requireID()), on: db)
    }

    @Test("The façade reports pending, then succeeded, as the VM converges")
    func facadeFollowsConvergence() async throws {
        try await withVMTestApp { app, user, vm, token in
            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)
            let event = try await record(.boot, on: vm, by: user, on: app.db)
            let eventID = try event.requireID()

            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .pending)
                #expect(operation.kind == .boot)
            }

            // The agent converges: observed generation reaches the target and
            // the observed status satisfies the desired one.
            vm.observedGeneration = vm.generation
            vm.setStatus(.running)
            try await vm.save(on: app.db)

            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .succeeded)
            }
        }
    }

    @Test("The façade reports failed when the VM is degraded at the mutation's generation")
    func facadeReportsDegradedAsFailed() async throws {
        try await withVMTestApp { app, user, vm, token in
            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)
            let event = try await record(.boot, on: vm, by: user, on: app.db)

            vm.lastError = "image download failed"
            vm.failedGeneration = vm.generation
            try await vm.save(on: app.db)

            try await app.test(.GET, "/api/operations/\(try event.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .failed)
                #expect(operation.error == "image download failed")
            }
        }
    }

    @Test("A superseded mutation reads as succeeded, not pending forever")
    func facadeReportsSupersededAsSucceeded() async throws {
        try await withVMTestApp { app, user, vm, token in
            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)
            let event = try await record(.boot, on: vm, by: user, on: app.db)

            // The agent reached this mutation's generation, and a newer
            // mutation has already moved the target on. The old one is not
            // pending — the reconciler is past it.
            vm.observedGeneration = vm.generation
            vm.setDesiredStatus(.shutdown)
            try await vm.save(on: app.db)

            try await app.test(.GET, "/api/operations/\(try event.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .succeeded)
            }
        }
    }

    @Test("A delete is visible to its initiator after the VM is gone, and hidden from others")
    func facadeAnswersDeleteAfterTheRowIsGone() async throws {
        try await withVMTestApp { app, user, vm, token in
            let vmID = try vm.requireID()
            ResourceFinalizerService.stampForDeletion(vm)
            vm.setDesiredStatus(.absent)
            try await vm.save(on: app.db)
            let event = try await record(.delete, on: vm, by: user, on: app.db)
            let eventID = try event.requireID()

            // Still terminating: not done.
            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .pending)
            }

            _ = try await ResourceFinalizerService.clear(.agentAbsent, from: vm, on: app.db, app: app)
            #expect(try await VM.find(vmID, on: app.db) == nil)

            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .succeeded)
                #expect(operation.completedAt != nil)
            }

            // 404 rather than 403 for a stranger, so the mutation's existence
            // is not leaked now that there is no resource to authorize against.
            let outsider = try await TestDataBuilder(db: app.db).createUser(
                username: "facade-outsider", email: "facade-outsider@example.com")
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)
            try await app.test(.GET, "/api/operations/\(eventID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("A terminal event is not addressable as an operation of its own")
    func facadeRefusesTerminalEventIds() async throws {
        try await withVMTestApp { app, user, vm, token in
            let terminal = try await ResourceEvent.record(
                .delete, resourceKind: .virtualMachine, resourceID: try vm.requireID(),
                actor: .user(try user.requireID()), phase: .completed, on: app.db)

            try await app.test(.GET, "/api/operations/\(try terminal.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("GET /api/vms/:id/operations merges recorded mutations with operation rows")
    func historyMergesBothSources() async throws {
        try await withVMTestApp { app, user, vm, token in
            let snapshotOp = ResourceOperation(vmID: vm.id!, userID: user.id!, kind: .snapshot)
            snapshotOp.status = .succeeded
            try await snapshotOp.save(on: app.db)
            snapshotOp.createdAt = Date().addingTimeInterval(-60)
            try await snapshotOp.save(on: app.db)

            _ = try await record(.boot, on: vm, by: user, on: app.db)

            try await app.test(.GET, "/api/vms/\(vm.id!)/operations") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let operations = try res.content.decode([OperationResponse].self)
                #expect(operations.map(\.kind) == [.boot, .snapshot])
            }
        }
    }

    // MARK: - Stuck-convergence sweep (STR-147)

    @Test("The sweep degrades a VM past its convergence deadline")
    func sweepDegradesOverdueConvergence() async throws {
        try await withVMTestApp { app, user, vm, _ in
            vm.setDesiredStatus(.running)
            vm.convergenceDeadline = Date().addingTimeInterval(-1)
            try await vm.save(on: app.db)
            _ = try await record(.boot, on: vm, by: user, on: app.db)

            await app.agentService.sweepStuckConvergence()

            let swept = try #require(try await VM.find(vm.id, on: app.db))
            #expect(swept.conditions.degraded?.reason.contains("Timed out") == true)
            // One behind the target: abandoning the unachieved intent is itself
            // a desired-state change, so the revert bumped the generation past
            // the one that failed.
            #expect(swept.conditions.degraded?.sinceGeneration == swept.generation - 1)
            // The deadline is cleared, so the row drops out of the next scan.
            #expect(swept.convergenceDeadline == nil)
            // The unachieved intent is abandoned rather than left to replay.
            #expect(swept.desiredStatus == .shutdown)
        }
    }

    @Test("The sweep is idempotent, so every replica can run it lock-free")
    func sweepIsIdempotent() async throws {
        try await withVMTestApp { app, user, vm, _ in
            vm.setDesiredStatus(.running)
            vm.convergenceDeadline = Date().addingTimeInterval(-1)
            try await vm.save(on: app.db)
            _ = try await record(.boot, on: vm, by: user, on: app.db)

            await app.agentService.sweepStuckConvergence()
            let first = try #require(try await VM.find(vm.id, on: app.db))
            let generation = first.generation
            let reason = first.lastError

            // A second pass — the other replica's, or the next tick's — finds
            // the deadline already claimed and changes nothing.
            await app.agentService.sweepStuckConvergence()

            let second = try #require(try await VM.find(vm.id, on: app.db))
            #expect(second.generation == generation)
            #expect(second.lastError == reason)
        }
    }

    @Test("The sweep leaves a VM that converged before its deadline alone")
    func sweepIgnoresConvergedVM() async throws {
        try await withVMTestApp { app, _, vm, _ in
            vm.setDesiredStatus(.shutdown)
            vm.observedGeneration = vm.generation
            vm.convergenceDeadline = Date().addingTimeInterval(-1)
            try await vm.save(on: app.db)

            await app.agentService.sweepStuckConvergence()

            let swept = try #require(try await VM.find(vm.id, on: app.db))
            #expect(swept.conditions.degraded == nil)
            #expect(swept.convergenceDeadline == nil)
        }
    }

    @Test("A stuck delete degrades without resurrecting the VM")
    func sweepDoesNotRevertATerminatingVM() async throws {
        try await withVMTestApp { app, user, vm, _ in
            ResourceFinalizerService.stampForDeletion(vm)
            vm.setDesiredStatus(.absent)
            vm.convergenceDeadline = Date().addingTimeInterval(-1)
            try await vm.save(on: app.db)
            _ = try await record(.delete, on: vm, by: user, on: app.db)

            await app.agentService.sweepStuckConvergence()

            let swept = try #require(try await VM.find(vm.id, on: app.db))
            #expect(swept.conditions.degraded != nil)
            // `.absent` is the one intent never abandoned: reverting it would
            // resurrect a VM the user deleted.
            #expect(swept.desiredStatus == .absent)
        }
    }
}
