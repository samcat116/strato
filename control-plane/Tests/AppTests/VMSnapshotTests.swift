import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Tests for the full-VM checkpoint surface (issue #564):
/// `POST/GET/DELETE /api/vms/:id/snapshots` and `.../restore` ride the
/// generalized 202-operation machinery, snapshot rows commit atomically with
/// the operation record, storage quota admits the estimated machine state, and
/// the agent RPC's verdict resolves the operation. No live agent socket exists
/// in these tests, so background RPCs fail fast — which exercises exactly the
/// failure bookkeeping (error rows, dropped charge, operation verdict).
@Suite("VM Snapshot Tests", .serialized)
final class VMSnapshotTests {

    private func withCheckpointTestApp(
        _ test: (Application, User, Project, VM, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "ckptuser",
                email: "ckpt@example.com",
                displayName: "Checkpoint User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Checkpoint Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Checkpoint Project",
                description: "Project for checkpoint tests",
                organization: org
            )
            let vm = try await builder.createVM(name: "ckpt-vm", project: project)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, project, vm, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// Registers an agent advertising the checkpoint message set and maps the
    /// VM onto it.
    @discardableResult
    private func placeOnCapableAgent(
        app: Application,
        vm: VM,
        capabilities: [String] = ["qemu", MessageType.vmCheckpoint.rawValue],
        status: VMStatus = .running
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: "checkpoint-agent",
            hostname: "test-host",
            version: "1.0.0",
            capabilities: capabilities,
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: WireProtocol.currentVersion
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: "checkpoint-agent",
            organizationScope: orgID.map { .organization($0) })

        vm.hypervisorId = agentUUID.uuidString
        vm.setStatus(status)
        vm.observedGeneration = 1
        vm.generation = 1
        // Converged: desired matches observed, so any later desired-state
        // movement in a test is something the checkpoint path did.
        if status == .running { vm.desiredStatus = .running }
        try await vm.save(on: app.db)
        return agentUUID.uuidString
    }

    /// Inserts a ready checkpoint directly, for the delete/restore paths that
    /// need one without driving a create through a live agent.
    private func insertReadyCheckpoint(
        app: Application, vm: VM, user: User, name: String = "ready-ckpt"
    ) async throws -> VMSnapshot {
        let snapshot = VMSnapshot(
            name: name,
            vmID: try vm.requireID(),
            projectID: vm.$project.id,
            environment: vm.environment,
            agentId: vm.hypervisorId,
            createdByID: try user.requireID())
        snapshot.status = .ready
        snapshot.size = 1 << 30
        try await snapshot.save(on: app.db)
        return snapshot
    }

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

    // MARK: - Create guards

    @Test("Checkpointing an unplaced VM is refused")
    func createRefusesUnplaced() async throws {
        try await withCheckpointTestApp { app, _, _, vm, token in
            try await app.test(.POST, "/api/vms/\(vm.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            #expect(try await VMSnapshot.query(on: app.db).count() == 0)
        }
    }

    @Test("Checkpointing a stopped VM is refused: there is no machine state to capture")
    func createRefusesStoppedVM() async throws {
        try await withCheckpointTestApp { app, _, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm, status: .shutdown)

            try await app.test(.POST, "/api/vms/\(vm.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("running or paused"))
            }
        }
    }

    @Test("Checkpointing via an agent without the capability is refused")
    func createRefusesIncapableAgent() async throws {
        try await withCheckpointTestApp { app, _, _, vm, token in
            // A QEMU-less (or pre-v22) agent drops the frame undecoded, so the
            // request would burn its whole budget against silence.
            try await placeOnCapableAgent(app: app, vm: vm, capabilities: ["qemu"])

            try await app.test(.POST, "/api/vms/\(vm.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains(MessageType.vmCheckpoint.rawValue))
            }
        }
    }

    @Test("A malformed checkpoint request body is rejected instead of defaulted")
    func createRejectsMalformedBody() async throws {
        try await withCheckpointTestApp { app, _, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)

            try await app.test(.POST, "/api/vms/\(vm.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["name": ["not", "a", "string"]])
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
            #expect(try await VMSnapshot.query(on: app.db).count() == 0)
        }
    }

    // MARK: - Create

    @Test("POST snapshots returns 202, inserts the estimated row, and fails cleanly without a live socket")
    func createAcceptsAndResolvesFailure() async throws {
        try await withCheckpointTestApp { app, user, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)

            var operation: OperationResponse?
            try await app.test(.POST, "/api/vms/\(vm.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["name": "before-upgrade"])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                operation = try res.content.decode(OperationResponse.self)
            }

            let accepted = try #require(operation)
            #expect(accepted.kind == .snapshot)
            #expect(accepted.resourceKind == .virtualMachine)
            #expect(accepted.resourceId == vm.id)

            let snapshot = try #require(
                await VMSnapshot.query(on: app.db).filter(\.$vm.$id == vm.id!).first())
            #expect(snapshot.name == "before-upgrade")
            #expect(snapshot.agentId == vm.hypervisorId)

            // Ownership: the creator gets an admin binding on the checkpoint
            // node in the create transaction.
            let ownerBindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == user.id!)
                .filter(\.$role == IAMRole.admin.seededID.uuidString)
                .filter(\.$nodeType == IAMNodeType.vmSnapshot.rawValue)
                .filter(\.$nodeID == snapshot.id!)
                .count()
            #expect(ownerBindings == 1)

            // No live agent socket: the background RPC fails fast, the
            // operation records the failure, and the row goes error with its
            // charge dropped.
            let completed = try await self.pollOperationCompleted(accepted.id!, on: app.db)
            #expect(completed?.status == .failed)
            let failed = try #require(await VMSnapshot.find(snapshot.id, on: app.db))
            #expect(failed.status == .error)
            #expect(failed.size == 0)

            // A checkpoint never touches the VM's desired state — the guest
            // keeps running through it — so the generation never moves either,
            // even across the failed operation's resolve-after-verdict.
            let settled = try #require(await VM.find(vm.id, on: app.db))
            #expect(settled.desiredStatus == .running)
            #expect(settled.generation == 1)
        }
    }

    @Test("A second checkpoint while one is pending is refused")
    func createRejectsConcurrentOperation() async throws {
        try await withCheckpointTestApp { app, user, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)

            // Park a pending operation on the VM by hand: the double-submit
            // guard is what this asserts, not the RPC.
            let pending = ResourceOperation(
                vmID: try vm.requireID(), userID: try user.requireID(), kind: .snapshot)
            try await pending.save(on: app.db)

            try await app.test(.POST, "/api/vms/\(vm.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    // MARK: - List

    @Test("GET snapshots pages a VM's checkpoints, newest first")
    func listReturnsCheckpoints() async throws {
        try await withCheckpointTestApp { app, user, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)
            _ = try await insertReadyCheckpoint(app: app, vm: vm, user: user, name: "first")
            _ = try await insertReadyCheckpoint(app: app, vm: vm, user: user, name: "second")

            try await app.test(.GET, "/api/vms/\(vm.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let page = try res.content.decode(PagedResponse<VMSnapshotResponse>.self)
                #expect(page.total == 2)
                #expect(Set(page.items.map(\.name)) == ["first", "second"])
            }
        }
    }

    // MARK: - Delete

    @Test("DELETE marks the checkpoint deleting and rides an operation")
    func deleteAcceptsAndMarksDeleting() async throws {
        try await withCheckpointTestApp { app, user, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)
            let snapshot = try await insertReadyCheckpoint(app: app, vm: vm, user: user)

            var operation: OperationResponse?
            try await app.test(
                .DELETE, "/api/vms/\(vm.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                operation = try res.content.decode(OperationResponse.self)
            }
            let accepted = try #require(operation)
            #expect(accepted.kind == .snapshotDelete)

            // Without a live socket the agent RPC fails, and the row stays
            // `.deleting` — which is retryable, since agent-side deletion is
            // idempotent.
            let completed = try await self.pollOperationCompleted(accepted.id!, on: app.db)
            #expect(completed?.status == .failed)
            let after = try #require(await VMSnapshot.find(snapshot.id, on: app.db))
            #expect(after.status == .deleting)
            #expect(after.canDelete)
        }
    }

    @Test("A checkpoint still creating cannot be deleted")
    func deleteRefusesCreatingCheckpoint() async throws {
        try await withCheckpointTestApp { app, user, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)
            let snapshot = try await insertReadyCheckpoint(app: app, vm: vm, user: user)
            snapshot.status = .creating
            try await snapshot.save(on: app.db)

            try await app.test(
                .DELETE, "/api/vms/\(vm.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("A checkpoint belonging to another VM is not found under this one")
    func deleteRefusesForeignCheckpoint() async throws {
        try await withCheckpointTestApp { app, user, project, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)
            let other = try await TestDataBuilder(db: app.db).createVM(
                name: "other-vm", project: project)
            let snapshot = try await insertReadyCheckpoint(app: app, vm: other, user: user)

            try await app.test(
                .DELETE, "/api/vms/\(vm.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    // MARK: - Restore

    @Test("Restore returns 202, flips desired state to running, and reverts it when the RPC fails")
    func restoreAcceptsAndSetsDesiredRunning() async throws {
        try await withCheckpointTestApp { app, user, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm, status: .paused)
            let snapshot = try await insertReadyCheckpoint(app: app, vm: vm, user: user)
            vm.setDesiredStatus(.paused)
            vm.generation = 1
            try await vm.save(on: app.db)

            var operation: OperationResponse?
            try await app.test(
                .POST, "/api/vms/\(vm.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)/restore"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                operation = try res.content.decode(OperationResponse.self)
            }
            let accepted = try #require(operation)
            #expect(accepted.kind == .restore)

            // The accept transaction flips desired state to running (a
            // restored guest resumes, and the next sync would pause it right
            // back otherwise), bumping the generation 1 → 2. With no live
            // agent socket the background RPC fails fast and the verdict
            // reverts desired state to observed (`.paused`, generation 3), so
            // reading right after the 202 races that revert. Wait out the
            // operation and assert the settled state instead: generation 3 is
            // only reachable through flip-then-revert, so it pins the accept
            // -transaction flip without the race.
            let completed = try await self.pollOperationCompleted(accepted.id!, on: app.db)
            #expect(completed?.status == .failed)
            var settled: VM?
            for _ in 0..<100 {
                settled = try await VM.find(vm.id, on: app.db)
                if settled?.generation == 3 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(settled?.generation == 3)
            #expect(settled?.desiredStatus == .paused)
        }
    }

    @Test("Restoring a checkpoint that is not ready is refused")
    func restoreRefusesUnreadyCheckpoint() async throws {
        try await withCheckpointTestApp { app, user, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)
            let snapshot = try await insertReadyCheckpoint(app: app, vm: vm, user: user)
            snapshot.status = .error
            try await snapshot.save(on: app.db)

            try await app.test(
                .POST, "/api/vms/\(vm.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)/restore"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("Restoring a checkpoint taken on another agent is refused")
    func restoreRefusesCrossAgent() async throws {
        try await withCheckpointTestApp { app, user, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)
            let snapshot = try await insertReadyCheckpoint(app: app, vm: vm, user: user)
            // The machine state lives inside disks on the agent that took it,
            // so a VM that moved cannot load it.
            snapshot.agentId = UUID().uuidString
            try await snapshot.save(on: app.db)

            try await app.test(
                .POST, "/api/vms/\(vm.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)/restore"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("cannot move between hosts"))
            }
        }
    }

    // MARK: - Quota

    @Test("Checkpoint state counts against the storage quota")
    func checkpointChargesStorageQuota() async throws {
        try await withCheckpointTestApp { app, user, project, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)

            // A quota with no headroom beyond the VM's own disk: the
            // checkpoint's estimated machine state (the memory grant) cannot
            // fit, so admission must reject it before any row is written.
            let quota = ResourceQuota(
                name: "tight",
                organizationID: nil,
                organizationalUnitID: nil,
                projectID: try project.requireID(),
                maxVCPUs: 64,
                maxMemory: 1 << 40,
                maxStorage: vm.disk,
                maxVMs: 10,
                environment: nil
            )
            try await quota.save(on: app.db)

            try await app.test(.POST, "/api/vms/\(vm.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.lowercased().contains("quota"))
            }
            #expect(try await VMSnapshot.query(on: app.db).count() == 0)

            // And a ready checkpoint's machine state shows up in the measured
            // storage usage, so a later admission sees it.
            let snapshot = try await insertReadyCheckpoint(app: app, vm: vm, user: user)
            let scope = try await QuotaUsageAggregator.scope(of: quota, on: app.db)
            let checkpointBytes = try await QuotaUsageAggregator.vmCheckpointStorageBytes(
                in: scope, on: app.db)
            #expect(checkpointBytes == snapshot.size)
        }
    }
}
