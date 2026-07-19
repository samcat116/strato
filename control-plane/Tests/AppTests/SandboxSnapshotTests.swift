import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Tests for the sandbox snapshot / checkpoint-resume surface (issue #426):
/// `POST/GET/DELETE /api/sandboxes/:id/snapshots` and `.../restore` ride the
/// generalized 202-operation machinery, snapshot rows and desired-state
/// changes commit atomically with the operation record, storage quota admits
/// the estimated footprint, and the agent RPC's verdict resolves the
/// operation. No live agent socket exists in these tests, so background RPCs
/// fail fast (`agentNotFound`) — which exercises exactly the failure
/// bookkeeping (error rows, quota release, desired-state revert).
@Suite("Sandbox Snapshot Tests", .serialized)
final class SandboxSnapshotTests {

    private func withSnapshotTestApp(
        _ test: (Application, User, Project, Sandbox, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "snapuser",
                email: "snap@example.com",
                displayName: "Snapshot User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Snapshot Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Snapshot Project",
                description: "Project for snapshot tests",
                organization: org
            )
            let sandbox = try await builder.createSandbox(name: "snap-sandbox", project: project)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, project, sandbox, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// Registers an agent advertising the sandbox-snapshot message set and
    /// maps the sandbox onto it as a running, agent-confirmed workload.
    private func placeOnCapableAgent(
        app: Application,
        sandbox: Sandbox,
        capabilities: [String] = ["firecracker", MessageType.sandboxSnapshotCreate.rawValue],
        status: SandboxStatus = .running
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: "snapshot-agent",
            hostname: "test-host",
            version: "1.0.0",
            capabilities: capabilities,
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: WireProtocol.currentVersion,
            sandboxCapable: true
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: "snapshot-agent",
            organizationScope: orgID.map { .organization($0) })

        sandbox.hypervisorId = agentUUID.uuidString
        sandbox.setStatus(status)
        sandbox.observedGeneration = 1
        sandbox.generation = 1
        if status == .running {
            sandbox.desiredStatus = .running
        }
        try await sandbox.save(on: app.db)
        return agentUUID.uuidString
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

    @Test("Snapshotting an unplaced sandbox is refused")
    func createRefusesUnplaced() async throws {
        try await withSnapshotTestApp { app, _, _, sandbox, token in
            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("Snapshotting a transitional sandbox is refused")
    func createRefusesTransitionalState() async throws {
        try await withSnapshotTestApp { app, _, _, sandbox, token in
            _ = try await placeOnCapableAgent(app: app, sandbox: sandbox, status: .starting)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("Snapshotting via an agent without the capability is refused")
    func createRefusesIncapableAgent() async throws {
        try await withSnapshotTestApp { app, _, _, sandbox, token in
            _ = try await placeOnCapableAgent(
                app: app, sandbox: sandbox, capabilities: ["firecracker"])

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("sandbox_snapshot_create"))
            }
        }
    }

    // MARK: - Create

    @Test("POST snapshots returns 202, inserts the estimated row, and fails cleanly without a live socket")
    func createAcceptsAndResolvesFailure() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, token in
            let recorder = SpiceDBMockRecorder()
            app.spicedbMockRecorder = recorder
            _ = try await placeOnCapableAgent(app: app, sandbox: sandbox, status: .running)

            var operation: OperationResponse?
            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["name": "before-upgrade"])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                operation = try res.content.decode(OperationResponse.self)
            }

            let accepted = try #require(operation)
            #expect(accepted.kind == .snapshot)
            #expect(accepted.resourceKind == .sandbox)
            #expect(accepted.resourceId == sandbox.id)

            // The row was inserted in the accept transaction. (Its `size`
            // starts as the admission estimate, but the background RPC can
            // fail — and zero it — before this read; the estimate's effect
            // is covered by the quota-rejection test.)
            let snapshot = try #require(
                await SandboxSnapshot.query(on: app.db)
                    .filter(\.$sandbox.$id == sandbox.id!)
                    .first())
            #expect(snapshot.name == "before-upgrade")
            #expect(snapshot.agentId == sandbox.hypervisorId)

            // Ownership tuples: owner, sandbox, project.
            let writes = await recorder.writes.filter { $0.entity == "sandbox_snapshot" }
            #expect(writes.contains { $0.relation == "owner" && $0.subjectId == user.id!.uuidString })
            #expect(writes.contains { $0.relation == "sandbox" && $0.subjectId == sandbox.id!.uuidString })

            // No live agent socket: the background RPC fails fast, the
            // operation records the failure, and the row goes error with its
            // charge dropped.
            let completed = try await self.pollOperationCompleted(accepted.id!, on: app.db)
            #expect(completed?.status == .failed)
            let failed = try #require(await SandboxSnapshot.find(snapshot.id, on: app.db))
            #expect(failed.status == .error)
            #expect(failed.size == 0)
        }
    }

    @Test("Checkpoint-and-stop flips desired state to stopped in the accept transaction")
    func createWithStopSetsDesiredStopped() async throws {
        try await withSnapshotTestApp { app, _, _, sandbox, token in
            _ = try await placeOnCapableAgent(app: app, sandbox: sandbox, status: .running)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["stop": true])
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let updated = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(updated.desiredStatus == .stopped)
            #expect(updated.generation == 2)
        }
    }

    @Test("A malformed snapshot request body is rejected instead of defaulted")
    func createRejectsMalformedBody() async throws {
        try await withSnapshotTestApp { app, _, _, sandbox, token in
            _ = try await placeOnCapableAgent(app: app, sandbox: sandbox, status: .running)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                // `stop` must be a Bool; masking this behind defaults would
                // silently run the wrong checkpoint mode.
                try req.content.encode(["stop": "yes-please"])
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let snapshots = try await SandboxSnapshot.query(on: app.db).count()
            #expect(snapshots == 0)
        }
    }

    @Test("A second mutation while the snapshot operation is pending is rejected with 409")
    func createBlocksConcurrentOperations() async throws {
        try await withSnapshotTestApp { app, _, _, sandbox, token in
            _ = try await placeOnCapableAgent(app: app, sandbox: sandbox, status: .running)

            // Insert a pending operation directly so the double-submit guard
            // is what rejects (the background resolver never runs for it).
            let pending = ResourceOperation(
                sandboxID: sandbox.id!, userID: UUID(), kind: .boot)
            try await pending.save(on: app.db)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("Storage quota admission rejects a snapshot that does not fit")
    func createRejectedByStorageQuota() async throws {
        try await withSnapshotTestApp { app, _, project, sandbox, token in
            _ = try await placeOnCapableAgent(app: app, sandbox: sandbox, status: .running)

            // Sandbox memory is 1 GiB; half a gigabyte of storage quota
            // cannot admit the estimate.
            let builder = TestDataBuilder(db: app.db)
            _ = try await builder.createResourceQuota(
                name: "tiny-storage",
                maxVCPUs: 10,
                maxMemoryGB: 20,
                maxStorageGB: 0.5,
                maxVMs: 5,
                project: project
            )

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.lowercased().contains("quota"))
            }

            // The rejection rolled the whole transaction back: no snapshot
            // row and no pending operation survive.
            let snapshots = try await SandboxSnapshot.query(on: app.db).count()
            #expect(snapshots == 0)
            let pending = try await ResourceOperation.query(on: app.db)
                .filter(\.$status == .pending)
                .count()
            #expect(pending == 0)
        }
    }

    // MARK: - List

    @Test("GET snapshots lists the sandbox's snapshots")
    func listReturnsSnapshots() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, token in
            let snapshot = SandboxSnapshot(
                name: "seeded",
                sandboxID: sandbox.id!,
                projectID: sandbox.$project.id,
                environment: sandbox.environment,
                agentId: "agent-1",
                createdByID: user.id!)
            snapshot.status = .ready
            snapshot.size = 42
            snapshot.guestControlProtocolVersion =
                SandboxGuestControlProtocol.currentVersion
            try await snapshot.save(on: app.db)

            try await app.test(.GET, "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let listed = try res.content.decode([SandboxSnapshotResponse].self)
                #expect(listed.count == 1)
                #expect(listed.first?.name == "seeded")
                #expect(listed.first?.status == .ready)
                #expect(listed.first?.size == 42)
                #expect(
                    listed.first?.guestControlProtocolVersion
                        == SandboxGuestControlProtocol.currentVersion)
            }
        }
    }

    // MARK: - Delete

    @Test("Deleting a snapshot with no reachable agent removes the row directly")
    func deleteWithoutAgentRemovesRow() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, token in
            let snapshot = SandboxSnapshot(
                name: "orphaned",
                sandboxID: sandbox.id!,
                projectID: sandbox.$project.id,
                environment: sandbox.environment,
                agentId: nil,
                createdByID: user.id!)
            snapshot.status = .ready
            try await snapshot.save(on: app.db)

            var operation: OperationResponse?
            try await app.test(
                .DELETE,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                operation = try res.content.decode(OperationResponse.self)
            }

            let accepted = try #require(operation)
            #expect(accepted.kind == .snapshotDelete)
            let completed = try await self.pollOperationCompleted(accepted.id!, on: app.db)
            #expect(completed?.status == .succeeded)
            let gone = try await SandboxSnapshot.find(snapshot.id, on: app.db)
            #expect(gone == nil)
        }
    }

    @Test("A creating snapshot cannot be deleted")
    func deleteRefusesCreating() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, token in
            let snapshot = SandboxSnapshot(
                name: "in-flight",
                sandboxID: sandbox.id!,
                projectID: sandbox.$project.id,
                environment: sandbox.environment,
                agentId: nil,
                createdByID: user.id!)
            try await snapshot.save(on: app.db)

            try await app.test(
                .DELETE,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    // MARK: - Restore

    @Test("A live fork protects its source snapshot and source sandbox")
    func liveForkProtectsLineage() async throws {
        try await withSnapshotTestApp { app, user, project, sandbox, token in
            let snapshot = SandboxSnapshot(
                name: "fork-source",
                sandboxID: sandbox.id!,
                projectID: project.id!,
                environment: sandbox.environment,
                agentId: nil,
                createdByID: user.id!)
            snapshot.status = .ready
            try await snapshot.save(on: app.db)

            let fork = Sandbox(
                name: "live-fork",
                projectID: project.id!,
                environment: sandbox.environment,
                image: sandbox.image,
                cpus: sandbox.cpus,
                memory: sandbox.memory,
                restoredFromSnapshotId: snapshot.id)
            try await fork.save(on: app.db)

            try await app.test(
                .DELETE,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("forked"))
            }

            try await app.test(
                .POST,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)/restore"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("live forks"))
            }

            try await app.test(.DELETE, "/api/sandboxes/\(sandbox.id!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("forks derived"))
            }
        }
    }

    @Test("Restore refuses a snapshot that is not ready")
    func restoreRefusesNotReady() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, token in
            let agentId = try await placeOnCapableAgent(app: app, sandbox: sandbox, status: .stopped)
            let snapshot = SandboxSnapshot(
                name: "broken",
                sandboxID: sandbox.id!,
                projectID: sandbox.$project.id,
                environment: sandbox.environment,
                agentId: agentId,
                createdByID: user.id!)
            snapshot.status = .error
            try await snapshot.save(on: app.db)

            try await app.test(
                .POST,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)/restore"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("Restore refuses when the sandbox moved off the snapshot's agent")
    func restoreRefusesAgentMismatch() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, token in
            _ = try await placeOnCapableAgent(app: app, sandbox: sandbox, status: .stopped)
            let snapshot = SandboxSnapshot(
                name: "elsewhere",
                sandboxID: sandbox.id!,
                projectID: sandbox.$project.id,
                environment: sandbox.environment,
                agentId: "some-other-agent",
                createdByID: user.id!)
            snapshot.status = .ready
            try await snapshot.save(on: app.db)

            try await app.test(
                .POST,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)/restore"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("cross-agent"))
            }
        }
    }

    @Test("Restore returns 202, sets desired running, and reverts on RPC failure")
    func restoreAcceptsAndRevertsOnFailure() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, token in
            let agentId = try await placeOnCapableAgent(app: app, sandbox: sandbox, status: .stopped)
            let snapshot = SandboxSnapshot(
                name: "checkpoint",
                sandboxID: sandbox.id!,
                projectID: sandbox.$project.id,
                environment: sandbox.environment,
                agentId: agentId,
                createdByID: user.id!)
            snapshot.status = .ready
            try await snapshot.save(on: app.db)

            var operation: OperationResponse?
            try await app.test(
                .POST,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)/restore"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                operation = try res.content.decode(OperationResponse.self)
            }

            let accepted = try #require(operation)
            #expect(accepted.kind == .restore)

            // The RPC fails fast (no socket): the operation records it and
            // the unachieved desired state reverts to observed reality. The
            // operation row and the sandbox revert are separate writes, so
            // poll the row the assertion is about.
            let completed = try await self.pollOperationCompleted(accepted.id!, on: app.db)
            #expect(completed?.status == .failed)
            var reverted = try #require(await Sandbox.find(sandbox.id, on: app.db))
            for _ in 0..<100 where reverted.desiredStatus != .stopped {
                try await Task.sleep(for: .milliseconds(50))
                reverted = try #require(await Sandbox.find(sandbox.id, on: app.db))
            }
            #expect(reverted.desiredStatus == .stopped)
            // Two generation bumps prove the accept transaction flipped
            // desired to running (gen 1 → 2) and the failure reverted it
            // (gen 2 → 3) — the transient running value itself can be gone
            // before any read lands.
            #expect(reverted.generation == 3)
        }
    }

    // MARK: - Quota accounting

    @Test("Quota resync counts non-error snapshot sizes into reserved storage")
    func quotaResyncCountsSnapshotStorage() async throws {
        try await withSnapshotTestApp { app, user, project, sandbox, _ in
            let builder = TestDataBuilder(db: app.db)
            let quota = try await builder.createResourceQuota(
                name: "storage-quota",
                maxStorageGB: 100,
                project: project
            )

            let ready = SandboxSnapshot(
                name: "counted",
                sandboxID: sandbox.id!,
                projectID: project.id!,
                environment: sandbox.environment,
                agentId: "agent-1",
                createdByID: user.id!)
            ready.status = .ready
            ready.size = 5 * 1024 * 1024 * 1024
            try await ready.save(on: app.db)

            let errored = SandboxSnapshot(
                name: "not-counted",
                sandboxID: sandbox.id!,
                projectID: project.id!,
                environment: sandbox.environment,
                agentId: "agent-1",
                createdByID: user.id!)
            errored.status = .error
            errored.size = 7 * 1024 * 1024 * 1024
            try await errored.save(on: app.db)

            let storage = try await quota.sandboxSnapshotStorageInScope(on: app.db)
            #expect(storage == 5 * 1024 * 1024 * 1024)
        }
    }

    @Test("Deleting the sandbox cascades its snapshot rows")
    func sandboxDeleteCascadesSnapshots() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, _ in
            let snapshot = SandboxSnapshot(
                name: "doomed",
                sandboxID: sandbox.id!,
                projectID: sandbox.$project.id,
                environment: sandbox.environment,
                agentId: nil,
                createdByID: user.id!)
            snapshot.status = .ready
            try await snapshot.save(on: app.db)

            try await sandbox.delete(on: app.db)

            let remaining = try await SandboxSnapshot.query(on: app.db).count()
            #expect(remaining == 0)
        }
    }
}
