import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
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

    /// Registers an agent with structured QEMU checkpoint support and maps the VM onto it.
    @discardableResult
    private func placeOnCapableAgent(
        app: Application,
        vm: VM,
        supportsSnapshots: Bool = true,
        status: VMStatus = .running,
        wireProtocolVersion: Int = WireProtocol.currentVersion
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: "checkpoint-agent",
            hostname: "test-host",
            version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            hypervisors: [
                HypervisorSupport(
                    type: .qemu,
                    available: true,
                    accelerated: true,
                    capabilities: HypervisorCapabilities(
                        type: .qemu,
                        supportsPause: true,
                        supportsLiveMigration: true,
                        supportsSnapshots: supportsSnapshots,
                        requiresDirectKernelBoot: false,
                        maxVCPUs: 1024,
                        maxMemory: 16 * 1024 * 1024 * 1024 * 1024))
            ],
            protocolVersion: wireProtocolVersion
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

    @Test("Checkpointing via an agent without snapshot support is refused")
    func createRefusesIncapableAgent() async throws {
        try await withCheckpointTestApp { app, _, _, vm, token in
            // A QEMU-less (or pre-v22) agent drops the frame undecoded, so the
            // request would burn its whole budget against silence.
            try await placeOnCapableAgent(app: app, vm: vm, supportsSnapshots: false)

            try await app.test(.POST, "/api/vms/\(vm.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("snapshot backend is unavailable"))
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

    @Test("POST snapshots returns 202 and inserts the checkpoint as desired state")
    func createAcceptsAsDesiredState() async throws {
        try await withCheckpointTestApp { app, user, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)

            var accepted: AcceptedMutation<VMSnapshotResponse>?
            try await app.test(.POST, "/api/vms/\(vm.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["name": "before-upgrade"])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedMutation<VMSnapshotResponse>.self)
            }

            let body = try #require(accepted)
            #expect(body.resource.name == "before-upgrade")
            #expect(body.targetGeneration == 1)
            // The client polls the checkpoint's own conditions now, and an
            // unconverged artifact is exactly what it should see first.
            #expect(!body.resource.conditions.converged)
            #expect(body.resource.conditions.observedGeneration == 0)

            let snapshot = try #require(
                await VMSnapshot.query(on: app.db).filter(\.$vm.$id == vm.id!).first())
            #expect(snapshot.agentId == vm.hypervisorId)
            #expect(snapshot.desiredStatus == .present)
            // Finalizers are stamped by the DELETE, not at create: re-stamping
            // a list on a live resource would resurrect tokens their
            // participants have already cleared.
            #expect(snapshot.finalizers.isEmpty)
            // The capture has a deadline, so a client is told the checkpoint
            // failed rather than polling one that will never appear.
            #expect(snapshot.convergenceDeadline != nil)
            // The admission estimate stands until the agent reports a real one;
            // an unknown footprint must never become a free one.
            #expect(snapshot.size == vm.memory)

            // The mutation is attributed in the same transaction as the insert.
            let event = try #require(
                await ResourceEvent.latest(
                    .requested, resourceKind: .vmCheckpoint, resourceID: snapshot.id!, on: app.db))
            #expect(event.id == body.mutationId)
            #expect(event.mutation == .create)

            // Ownership: the creator gets an admin binding on the checkpoint
            // node in the create transaction.
            let ownerBindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == user.id!)
                .filter(\.$roleID == IAMRole.admin.seededID)
                .filter(\.$nodeType == IAMNodeType.vmSnapshot.rawValue)
                .filter(\.$nodeID == snapshot.id!)
                .count()
            #expect(ownerBindings == 1)

            // A checkpoint never touches the VM's desired state — the guest
            // keeps running through it — so the VM's generation never moves.
            let settled = try #require(await VM.find(vm.id, on: app.db))
            #expect(settled.desiredStatus == .running)
            #expect(settled.generation == 1)
        }
    }

    /// The "operation already pending" mutex is gone with the operation row
    /// (STR-147, extended to artifacts here). Overlapping captures are safe:
    /// each is its own artifact with its own generation, and a replayed sync
    /// cannot re-capture one that already exists.
    @Test("A second checkpoint while one is converging is accepted, not refused")
    func createAllowsConcurrentCaptures() async throws {
        try await withCheckpointTestApp { app, _, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)

            for name in ["first", "second"] {
                try await app.test(.POST, "/api/vms/\(vm.id!.uuidString)/snapshots") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(["name": name])
                } afterResponse: { res in
                    #expect(res.status == .accepted)
                }
            }
            #expect(try await VMSnapshot.query(on: app.db).count() == 2)
        }
    }

    /// Retention is the answer durable artifact objects need and
    /// fire-and-forget RPCs never raised (`SnapshotRetention`).
    @Test("A requested TTL becomes an absolute expiry; zero keeps it forever")
    func createStampsRetention() async throws {
        try await withCheckpointTestApp { app, _, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)

            try await app.test(.POST, "/api/vms/\(vm.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMSnapshotRequest(name: "expiring", description: nil, ttlSeconds: 3600))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
            let expiring = try #require(
                await VMSnapshot.query(on: app.db).filter(\.$name == "expiring").first())
            let expiresAt = try #require(expiring.expiresAt)
            #expect(expiresAt.timeIntervalSinceNow > 3000)

            try await app.test(.POST, "/api/vms/\(vm.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMSnapshotRequest(name: "kept", description: nil, ttlSeconds: 0))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
            let kept = try #require(
                await VMSnapshot.query(on: app.db).filter(\.$name == "kept").first())
            #expect(kept.expiresAt == nil)
        }
    }

    @Test("A negative TTL is rejected")
    func createRejectsNegativeTTL() async throws {
        try await withCheckpointTestApp { app, _, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)

            try await app.test(.POST, "/api/vms/\(vm.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMSnapshotRequest(name: "bad", description: nil, ttlSeconds: -1))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
            #expect(try await VMSnapshot.query(on: app.db).count() == 0)
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

    @Test("DELETE marks the checkpoint absent and keeps the row until an agent confirms")
    func deleteAcceptsAndMarksAbsent() async throws {
        try await withCheckpointTestApp { app, user, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)
            let snapshot = try await insertReadyCheckpoint(app: app, vm: vm, user: user)

            try await app.test(
                .DELETE, "/api/vms/\(vm.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            // The row outlives the request. This is the whole durability
            // property the imperative path could not offer: an RPC whose reply
            // was lost left a row marked `.deleting` with nothing to retry it,
            // where this one is re-driven by every level-triggered sync until
            // the agent's report omits the artifact.
            let after = try #require(await VMSnapshot.find(snapshot.id, on: app.db))
            #expect(after.desiredStatus == .absent)
            #expect(after.finalizers == [ResourceFinalizer.agentAbsent.rawValue])
            #expect(after.generation > snapshot.generation)
        }
    }

    /// Deleting an artifact whose agent can never confirm — unplaced, offline,
    /// or below wire v33 — force-clears the finalizer, so upgrading the control
    /// plane before the fleet cannot make checkpoints permanently undeletable.
    @Test("Deleting a checkpoint with no reachable agent removes the row directly")
    func deleteWithoutAgentRemovesRow() async throws {
        try await withCheckpointTestApp { app, user, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm)
            let snapshot = try await insertReadyCheckpoint(app: app, vm: vm, user: user)
            snapshot.agentId = nil
            try await snapshot.save(on: app.db)

            try await app.test(
                .DELETE, "/api/vms/\(vm.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            var removed = false
            for _ in 0..<40 {
                if try await VMSnapshot.find(snapshot.id, on: app.db) == nil {
                    removed = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(removed)
        }
    }

    /// The `.creating` refusal is gone with the operation row that owned the
    /// checkpoint's resolution. Deletion is level-triggered and the agent's
    /// teardown is idempotent, so there is no half-finished capture a delete
    /// could interrupt into an inconsistent state.
    @Test("A checkpoint still capturing can be deleted")
    func deleteAcceptsCreatingCheckpoint() async throws {
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
                #expect(res.status == .accepted)
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

    @Test("Restore returns 202 and writes the restore nonce onto the VM")
    func restoreAcceptsAndSetsDesiredRunning() async throws {
        try await withCheckpointTestApp { app, user, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm, status: .paused)
            let snapshot = try await insertReadyCheckpoint(app: app, vm: vm, user: user)
            vm.setFixtureDesiredStatus(.paused)
            vm.generation = 1
            try await vm.save(on: app.db)

            var accepted: AcceptedMutation<VMDetailResponse>?
            try await app.test(
                .POST, "/api/vms/\(vm.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)/restore"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedMutation<VMDetailResponse>.self)
            }
            // Answers with the VM and the generation to wait for, like every
            // other mutation since STR-147 — there is no operation row to poll.
            let body = try #require(accepted)
            #expect(body.targetGeneration == 2)

            // The restore is an edge-nonce (STR-151): a monotonic counter and
            // the checkpoint it names, applied once by the agent against its own
            // durable record. Desired state flips to running alongside, because
            // a restored guest resumes and the next sync would otherwise pause
            // it right back.
            let stored = try await VM.find(vm.id, on: app.db)
            #expect(stored?.restoreGeneration == 1)
            #expect(stored?.restoreSnapshotID == snapshot.id)
            #expect(stored?.desiredStatus == .running)
            #expect(stored?.generation == 2)
            #expect(stored?.rebootGeneration == 0)

            // Nothing was dispatched and nothing awaited a reply: the sync is
            // the whole delivery mechanism now.
            let events = try await ResourceEvent.query(on: app.db)
                .filter(\.$resourceID == vm.id!)
                .filter(\.$mutation == .restore)
                .all()
            #expect(events.count == 1)
            #expect(events.first?.targetGeneration == 2)
        }
    }

    /// The second of the two signals issue #415 established. A v34 agent on a
    /// host with no usable QEMU reads the nonce and can do nothing with it, so
    /// admitting the restore would surface as a `degraded` condition half an
    /// hour later instead of a `409` naming the remedy. The capture path checks
    /// the same pair, so admission stays symmetric.
    @Test("Restore is refused when the agent advertises no checkpoint backend")
    func restoreRefusesAgentWithoutCheckpointCapability() async throws {
        try await withCheckpointTestApp { app, user, _, vm, token in
            try await placeOnCapableAgent(app: app, vm: vm, supportsSnapshots: false)
            let snapshot = try await insertReadyCheckpoint(app: app, vm: vm, user: user)

            try await app.test(
                .POST, "/api/vms/\(vm.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)/restore"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("snapshot backend"))
            }

            #expect(try await VM.find(vm.id, on: app.db)?.restoreGeneration == 0)
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
