import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
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
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
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

    /// Registers an agent with structured Firecracker snapshot support and
    /// maps the sandbox onto it as a running, agent-confirmed workload.
    private func placeOnCapableAgent(
        app: Application,
        sandbox: Sandbox,
        supportsSnapshots: Bool = true,
        status: SandboxStatus = .running,
        wireProtocolVersion: Int = WireProtocol.currentVersion
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: "snapshot-agent",
            hostname: "test-host",
            version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            hypervisors: [
                HypervisorSupport(
                    type: .firecracker,
                    available: true,
                    accelerated: true,
                    capabilities: HypervisorCapabilities(
                        type: .firecracker,
                        supportsPause: true,
                        supportsLiveMigration: false,
                        supportsSnapshots: supportsSnapshots,
                        requiresDirectKernelBoot: true,
                        maxVCPUs: 32,
                        maxMemory: 32 * 1024 * 1024 * 1024))
            ],
            protocolVersion: wireProtocolVersion,
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

    @Test("Snapshotting via an agent without snapshot support is refused")
    func createRefusesIncapableAgent() async throws {
        try await withSnapshotTestApp { app, _, _, sandbox, token in
            _ = try await placeOnCapableAgent(
                app: app, sandbox: sandbox, supportsSnapshots: false)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("snapshot backend is unavailable"))
            }
        }
    }

    // MARK: - Create

    @Test("POST snapshots returns 202 and inserts the snapshot as desired state")
    func createAcceptsAsDesiredState() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, token in
            _ = try await placeOnCapableAgent(app: app, sandbox: sandbox, status: .running)

            var accepted: AcceptedMutation<SandboxSnapshotResponse>?
            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["name": "before-upgrade"])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedMutation<SandboxSnapshotResponse>.self)
            }

            let body = try #require(accepted)
            #expect(body.resource.name == "before-upgrade")
            #expect(body.targetGeneration == 1)
            #expect(!body.resource.conditions.converged)

            let snapshot = try #require(
                await SandboxSnapshot.query(on: app.db)
                    .filter(\.$sandbox.$id == sandbox.id!)
                    .first())
            #expect(snapshot.agentId == sandbox.hypervisorId)
            #expect(snapshot.desiredStatus == .present)
            // The admission estimate stands until the agent reports a real
            // figure on its observed report; an unmeasured footprint must never
            // silently become a free one.
            #expect(snapshot.size == sandbox.memory)
            // Resume is the default capture mode, and it is durable: a desired
            // entry is re-assembled on every sync, long after this request.
            #expect(snapshot.captureMode == .resume)

            // Ownership: the creator gets an admin binding on the snapshot
            // node in the create transaction.
            let ownerBindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == user.id!)
                .filter(\.$roleID == IAMRole.admin.seededID)
                .filter(\.$nodeType == IAMNodeType.sandboxSnapshot.rawValue)
                .filter(\.$nodeID == snapshot.id!)
                .count()
            #expect(ownerBindings == 1)
        }
    }

    /// Checkpoint-and-stop has two halves, and both have to land in the same
    /// transaction. The *capture* leaves the microVM paused, which the agent
    /// reads off the artifact's durable `captureMode`; the *lasting* intent is
    /// the sandbox's own desired state, so the reconciler does not resume it on
    /// the next level-triggered pass.
    @Test("Checkpoint-and-stop records the capture mode and stops the sandbox")
    func createWithStopSetsDesiredStopped() async throws {
        try await withSnapshotTestApp { app, _, _, sandbox, token in
            _ = try await placeOnCapableAgent(app: app, sandbox: sandbox, status: .running)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["stop": true])
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let snapshot = try #require(
                await SandboxSnapshot.query(on: app.db)
                    .filter(\.$sandbox.$id == sandbox.id!)
                    .first())
            #expect(snapshot.captureMode == .stop)

            let settled = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(settled.desiredStatus == .stopped)
            #expect(settled.generation == 2)
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

    /// The "operation already pending" mutex is gone with the operation row
    /// (STR-147, extended to artifacts in STR-150). A snapshot is its own
    /// resource with its own generation, so it no longer contends with the
    /// sandbox's other mutations at all.
    @Test("A snapshot is accepted while another sandbox mutation is pending")
    func createAllowsConcurrentOperations() async throws {
        try await withSnapshotTestApp { app, _, _, sandbox, token in
            _ = try await placeOnCapableAgent(app: app, sandbox: sandbox, status: .running)

            // An unconverged boot on the sandbox: desired state moved, the
            // agent has not caught up.
            sandbox.setFixtureDesiredStatus(.running)
            sandbox.extendConvergenceDeadline(by: 600)
            try await sandbox.save(on: app.db)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
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

            // The rejection rolled the whole transaction back: no snapshot row
            // and no recorded mutation survive.
            let snapshots = try await SandboxSnapshot.query(on: app.db).count()
            #expect(snapshots == 0)
            let requested = try await ResourceEvent.query(on: app.db)
                .filter(\.$resourceKind == .sandboxSnapshot)
                .count()
            #expect(requested == 0)
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
            snapshot.forkLayoutVersion = SandboxSnapshotForkLayout.currentVersion
            try await snapshot.save(on: app.db)

            try await app.test(.GET, "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let listed = try res.content.decode(PagedResponse<SandboxSnapshotResponse>.self).items
                #expect(listed.count == 1)
                #expect(listed.first?.name == "seeded")
                #expect(listed.first?.status == .ready)
                #expect(listed.first?.size == 42)
                #expect(
                    listed.first?.guestControlProtocolVersion
                        == SandboxGuestControlProtocol.currentVersion)
                #expect(listed.first?.forkLayoutVersion == SandboxSnapshotForkLayout.currentVersion)
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

            try await app.test(
                .DELETE,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            var removed = false
            for _ in 0..<40 {
                if try await SandboxSnapshot.find(snapshot.id, on: app.db) == nil {
                    removed = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(removed)
        }
    }

    /// The `.creating` refusal is gone with the operation row that owned the
    /// snapshot's resolution. Deletion is level-triggered and the agent's
    /// teardown is idempotent, so there is no half-finished capture a delete
    /// could interrupt into an inconsistent state (STR-150).
    @Test("A snapshot still capturing can be deleted")
    func deleteAcceptsCreating() async throws {
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
                #expect(res.status == .accepted)
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

    @Test("Restore returns 202 and writes the restore nonce onto the sandbox")
    func restoreAcceptsAndWritesTheNonce() async throws {
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

            var accepted: AcceptedMutation<SandboxDetailResponse>?
            try await app.test(
                .POST,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)/restore"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedMutation<SandboxDetailResponse>.self)
            }
            let body = try #require(accepted)
            #expect(body.targetGeneration == 2)

            // A restore is an edge-nonce (STR-151): a count of how many times it
            // was asked for plus the snapshot it names, applied once by the
            // agent against its own durable record. Desired state flips to
            // running alongside — a restored guest resumes.
            let stored = try await Sandbox.find(sandbox.id, on: app.db)
            #expect(stored?.restoreGeneration == 1)
            #expect(stored?.restoreSnapshotID == snapshot.id)
            #expect(stored?.desiredStatus == .running)
            #expect(stored?.generation == 2)
            // Distinct from the fork lineage field, which a rewind never touches.
            #expect(stored?.restoredFromSnapshotId == nil)
        }
    }

    /// Wire compatibility and backend support are different questions (issue
    /// #415): an agent with no sandbox-snapshot backend reads the nonce and can do nothing
    /// with it, which would surface as a `degraded` condition an hour later
    /// rather than a `409` naming the remedy.
    @Test("Restore is refused when the agent advertises no snapshot backend")
    func restoreRefusesAgentWithoutSnapshotCapability() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, token in
            let agentId = try await placeOnCapableAgent(
                app: app, sandbox: sandbox, supportsSnapshots: false, status: .stopped)
            let snapshot = SandboxSnapshot(
                name: "checkpoint",
                sandboxID: sandbox.id!,
                projectID: sandbox.$project.id,
                environment: sandbox.environment,
                agentId: agentId,
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
                #expect(res.body.string.contains("snapshot backend"))
            }

            #expect(try await Sandbox.find(sandbox.id, on: app.db)?.restoreGeneration == 0)
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

    // MARK: - Mobility (issue #428)

    /// Registers an agent with the full mobility surface: current wire
    /// protocol, an available Firecracker with a probed version, host CPU
    /// model, and architecture — the compatibility inputs cross-agent
    /// restore placement reads.
    private func registerMobilityAgent(
        app: Application,
        named name: String,
        firecrackerVersion: String? = "1.7.0",
        cpuModel: String? = "TestCPU 3000",
        architecture: CPUArchitecture? = CPUArchitecture.current,
        protocolVersion: Int = WireProtocol.currentVersion
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: name,
            hostname: "\(name)-host",
            version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            architecture: architecture,
            hypervisors: [
                HypervisorSupport(
                    type: .firecracker, available: true, accelerated: true,
                    capabilities: .firecracker, version: firecrackerVersion)
            ],
            protocolVersion: protocolVersion,
            sandboxCapable: true,
            hostInfo: HostInfo(cpuModel: cpuModel)
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: name,
            organizationScope: orgID.map { .organization($0) })
        return agentUUID.uuidString
    }

    /// Seeds a ready snapshot with a complete export record.
    private func seedExportedSnapshot(
        app: Application, user: User, sandbox: Sandbox,
        agentId: String?,
        firecrackerVersion: String? = "1.7.0",
        architecture: String? = CPUArchitecture.current.rawValue,
        cpuTemplate: String? = nil,
        sourceCPUModel: String? = "TestCPU 3000"
    ) async throws -> SandboxSnapshot {
        let snapshot = SandboxSnapshot(
            name: "exported",
            sandboxID: sandbox.id!,
            projectID: sandbox.$project.id,
            environment: sandbox.environment,
            agentId: agentId,
            createdByID: user.id!)
        snapshot.status = .ready
        snapshot.size = 64
        snapshot.firecrackerVersion = firecrackerVersion
        snapshot.architecture = architecture
        snapshot.cpuTemplate = cpuTemplate
        snapshot.sourceCPUModel = sourceCPUModel
        snapshot.guestControlProtocolVersion = SandboxGuestControlProtocol.currentVersion
        snapshot.forkLayoutVersion = SandboxSnapshotForkLayout.currentVersion
        snapshot.exportedArtifacts = SandboxSnapshotArtifactKind.allCases.map {
            SandboxSnapshotExportedArtifact(kind: $0, sizeBytes: 16, sha256: String(repeating: "0", count: 64))
        }
        snapshot.exportedAt = Date()
        try await snapshot.save(on: app.db)
        return snapshot
    }

    @Test("Export refuses a snapshot that is not ready")
    func exportRefusesNotReady() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, token in
            let agentId = try await placeOnCapableAgent(app: app, sandbox: sandbox)
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
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)/export"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    /// Export is a placement fact, not a verb (STR-150): the request records
    /// that a copy *should* exist and the agent converges by uploading. The
    /// snapshot stays unconverged until the upload route has hashed every
    /// artifact itself — the agent's word is never enough.
    @Test("Export returns 202 and records the desire without completing it")
    func exportAcceptsAsPlacementFact() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, token in
            let agentId = try await placeOnCapableAgent(app: app, sandbox: sandbox)
            let snapshot = SandboxSnapshot(
                name: "to-export",
                sandboxID: sandbox.id!,
                projectID: sandbox.$project.id,
                environment: sandbox.environment,
                agentId: agentId,
                createdByID: user.id!)
            snapshot.status = .ready
            snapshot.observedGeneration = snapshot.generation
            try await snapshot.save(on: app.db)

            var accepted: AcceptedMutation<SandboxSnapshotResponse>?
            try await app.test(
                .POST,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)/export"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedMutation<SandboxSnapshotResponse>.self)
            }

            let body = try #require(accepted)
            #expect(body.resource.exportDesired)
            #expect(!body.resource.conditions.converged)
            let current = try #require(await SandboxSnapshot.find(snapshot.id, on: app.db))
            #expect(current.exportDesired)
            #expect(current.generation > snapshot.observedGeneration)
            #expect(current.exportedAt == nil)
            // A failed export leaves the snapshot itself untouched.
            #expect(current.status == .ready)
        }
    }

    @Test("Agent mTLS artifact upload records integrity and download streams the bytes back")
    func artifactUploadAndDownloadRoundTripOverAgentMTLS() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, _ in
            let storeRoot = NSTemporaryDirectory() + "snapshot-transfer-\(UUID().uuidString)"
            app.imageObjectStore = FilesystemImageObjectStore(rootPath: storeRoot)
            defer { try? FileManager.default.removeItem(atPath: storeRoot) }

            // XFCC trust requires loopback provenance, which Vapor's in-memory
            // test harness cannot provide — bind a real ephemeral port (the
            // ImageDownloadMTLSTests pattern) and rely on the XFCC URI alone
            // (no trust bundle configured).
            app.spireService = SPIREService(
                config: SPIREServiceConfig(enabled: true, trustDomain: "strato.local"),
                logger: app.logger, httpClient: app.client)
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let outcome: Result<Void, any Error>
            do {
                let port = try #require(
                    app.http.server.shared.localAddress?.port,
                    "HTTP server did not report a bound port")

                let snapshot = SandboxSnapshot(
                    name: "transfer",
                    sandboxID: sandbox.id!,
                    projectID: sandbox.$project.id,
                    environment: sandbox.environment,
                    agentId: "agent-a",
                    createdByID: user.id!)
                snapshot.status = .ready
                snapshot.size = 1 << 20
                try await snapshot.save(on: app.db)

                let payload = "checkpointed guest memory bytes"
                let path = SandboxSnapshot.artifactTransferPath(
                    sandboxId: sandbox.id!, snapshotId: snapshot.id!, kind: .memory)
                let uri = URI(string: "http://127.0.0.1:\(port)\(path)")
                let xfcc = ("X-Forwarded-Client-Cert", "URI=spiffe://strato.local/agent/transfer-agent")

                let uploadResponse = try await app.client.put(uri) { req in
                    req.headers.add(name: xfcc.0, value: xfcc.1)
                    req.body = ByteBuffer(string: payload)
                }
                #expect(uploadResponse.status == .ok)

                let uploaded = try #require(await SandboxSnapshot.find(snapshot.id, on: app.db))
                let recorded = try #require(uploaded.exportedArtifact(for: .memory))
                #expect(recorded.sizeBytes == Int64(payload.utf8.count))
                #expect(recorded.sha256.count == 64)
                // The export operation stamps completion, not the upload
                // route — one landed artifact is not a complete export. (An
                // artifact landing does *not* clear a prior stamp; see
                // `reExportDoesNotClearPriorExport`.)
                #expect(uploaded.exportedAt == nil)

                let downloadResponse = try await app.client.get(uri) { req in
                    req.headers.add(name: xfcc.0, value: xfcc.1)
                }
                #expect(downloadResponse.status == .ok)
                let body = downloadResponse.body.map { String(buffer: $0) } ?? ""
                #expect(body == payload)

                // No forwarded certificate at all: refused, with no session
                // fallback — these routes exist only for agents.
                let anonymous = try await app.client.get(uri)
                #expect(anonymous.status == .unauthorized)

                // A non-agent SPIFFE identity is refused too.
                let nonAgent = try await app.client.get(uri) { req in
                    req.headers.add(
                        name: xfcc.0, value: "URI=spiffe://strato.local/control-plane")
                }
                #expect(nonAgent.status == .forbidden)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await app.server.shutdown()
            try outcome.get()
        }
    }

    @Test("Cross-agent restore refuses an incompatible target and accepts a compatible one")
    func crossAgentRestoreCompatibilityGate() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, token in
            // Target agent: current wire, Firecracker 1.7.0, known CPU model.
            let targetId = try await registerMobilityAgent(app: app, named: "restore-target")
            sandbox.hypervisorId = targetId
            sandbox.setStatus(.stopped)
            sandbox.observedGeneration = 1
            sandbox.generation = 1
            try await sandbox.save(on: app.db)

            // Firecracker version mismatch blocks the restore.
            let mismatched = try await seedExportedSnapshot(
                app: app, user: user, sandbox: sandbox,
                agentId: "some-other-agent", firecrackerVersion: "1.6.0")
            try await app.test(
                .POST,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(mismatched.id!.uuidString)/restore"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("Firecracker"))
            }

            // An un-templated snapshot from a different CPU model is blocked.
            let cpuMismatch = try await seedExportedSnapshot(
                app: app, user: user, sandbox: sandbox,
                agentId: "some-other-agent", sourceCPUModel: "OtherCPU 9000")
            try await app.test(
                .POST,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(cpuMismatch.id!.uuidString)/restore"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("CPU template"))
            }

            // Same Firecracker + identical CPU model: accepted (202). The gate
            // under test is the accept; the nonce it writes is what the target
            // agent converges on, and the exported artifacts' descriptors are
            // resolved at sync assembly rather than stored here.
            let compatible = try await seedExportedSnapshot(
                app: app, user: user, sandbox: sandbox, agentId: "some-other-agent")
            try await app.test(
                .POST,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(compatible.id!.uuidString)/restore"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
            let stored = try await Sandbox.find(sandbox.id, on: app.db)
            #expect(stored?.restoreGeneration == 1)
            #expect(stored?.restoreSnapshotID == compatible.id)
        }
    }

    @Test("Cross-agent restore of an unexported snapshot demands an export")
    func crossAgentRestoreRequiresExport() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, token in
            let targetId = try await registerMobilityAgent(app: app, named: "unexported-target")
            sandbox.hypervisorId = targetId
            sandbox.setStatus(.stopped)
            sandbox.observedGeneration = 1
            try await sandbox.save(on: app.db)

            let snapshot = SandboxSnapshot(
                name: "local-only",
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
                #expect(res.body.string.contains("export"))
            }
        }
    }

    @Test("Deleting an exported snapshot removes its objects from the store")
    func deleteRemovesExportedObjects() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, token in
            let storeRoot = NSTemporaryDirectory() + "snapshot-delete-\(UUID().uuidString)"
            app.imageObjectStore = FilesystemImageObjectStore(rootPath: storeRoot)
            defer { try? FileManager.default.removeItem(atPath: storeRoot) }

            let snapshot = try await seedExportedSnapshot(
                app: app, user: user, sandbox: sandbox, agentId: nil)
            let key = SandboxSnapshotObjectKey.artifact(
                projectId: sandbox.$project.id, snapshotId: snapshot.id!, kind: .memory)
            let writer = try await app.imageObjectStore.openWriter(key: key)
            try await writer.write(ByteBuffer(string: "bytes"))
            try await writer.finish()
            // Hoisted out of `#expect`: `#expect(try await …)` crashes the
            // Xcode 27 beta compiler.
            let stored = try await app.imageObjectStore.exists(key: key)
            #expect(stored)

            try await app.test(
                .DELETE,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
            // The exported copy is removed by `SandboxSnapshot.reap`, which
            // runs when the last finalizer clears — here immediately, since the
            // snapshot has no agent to confirm anything.
            var stillThere = true
            for _ in 0..<40 {
                stillThere = (try? await app.imageObjectStore.exists(key: key)) ?? false
                if !stillThere { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(!stillThere)
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

    // MARK: - Export admission (issue #428 review)

    @Test("Export is denied for an operator (sandbox:export is editor and above)")
    func exportRequiresExportPermission() async throws {
        try await withSnapshotTestApp { app, user, project, sandbox, _ in
            // An operator can drive the sandbox lifecycle but holds neither
            // sandbox:snapshot nor sandbox:export — the per-verb gate now
            // falls out of role membership (the registry pins which roles
            // carry export; CedarSchemaTests prove the closure).
            let builder = TestDataBuilder(db: app.db)
            let operatorUser = try await builder.createUser(
                username: "snap-operator", email: "snap-operator@example.com")
            try await RoleBindingService.grant(
                principalType: .user, principalID: operatorUser.id!, role: .operator,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)
            let token = try await operatorUser.generateAPIKey(on: app.db)
            let agentId = try await placeOnCapableAgent(app: app, sandbox: sandbox)
            let snapshot = SandboxSnapshot(
                name: "viewer-cannot-export",
                sandboxID: sandbox.id!,
                projectID: sandbox.$project.id,
                environment: sandbox.environment,
                agentId: agentId,
                createdByID: user.id!)
            snapshot.status = .ready
            try await snapshot.save(on: app.db)

            try await app.test(
                .POST,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)/export"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            // Nothing was recorded: admission refused before anything started.
            let requested = try await ResourceEvent.query(on: app.db)
                .filter(\.$resourceKind == .sandboxSnapshot)
                .count()
            #expect(requested == 0)
        }
    }

    @Test("Export is refused when the exported copy would exceed the storage quota")
    func exportRespectsStorageQuota() async throws {
        try await withSnapshotTestApp { app, user, project, sandbox, token in
            let agentId = try await placeOnCapableAgent(app: app, sandbox: sandbox)
            let snapshot = SandboxSnapshot(
                name: "too-big-to-export",
                sandboxID: sandbox.id!,
                projectID: sandbox.$project.id,
                environment: sandbox.environment,
                agentId: agentId,
                createdByID: user.id!)
            snapshot.status = .ready
            snapshot.size = 8 << 30
            try await snapshot.save(on: app.db)

            // A pool with room for the on-agent copy already counted, but not
            // for a second one in object storage.
            let quota = ResourceQuota(
                name: "snapshot-storage",
                projectID: try project.requireID(),
                maxVCPUs: 64,
                maxMemory: 64 << 30,
                maxStorage: 12 << 30,
                maxVMs: 32,
                maxSandboxes: 32)
            try await quota.save(on: app.db)

            try await app.test(
                .POST,
                "/api/sandboxes/\(sandbox.id!.uuidString)/snapshots/\(snapshot.id!.uuidString)/export"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.lowercased().contains("quota"))
            }
        }
    }

    @Test("Exported artifacts count as a second copy against snapshot storage")
    func exportedCopyCountsTowardStorage() async throws {
        try await withSnapshotTestApp { app, user, project, sandbox, _ in
            let snapshot = try await seedExportedSnapshot(
                app: app, user: user, sandbox: sandbox, agentId: "agent-a")
            let quota = ResourceQuota(
                name: "scope",
                projectID: try project.requireID(),
                maxVCPUs: 64,
                maxMemory: 64 << 30,
                maxStorage: 64 << 30,
                maxVMs: 32,
                maxSandboxes: 32)
            try await quota.save(on: app.db)

            let exportedBytes = (snapshot.exportedArtifacts ?? []).reduce(Int64(0)) { $0 + $1.sizeBytes }
            let inScope = try await quota.sandboxSnapshotStorageInScope(on: app.db)
            #expect(inScope == (snapshot.size ?? 0) + exportedBytes)
            #expect(exportedBytes > 0)
        }
    }

    @Test("Re-uploading an artifact leaves an existing export record intact")
    func reExportDoesNotClearPriorExport() async throws {
        try await withSnapshotTestApp { app, user, _, sandbox, _ in
            let storeRoot = NSTemporaryDirectory() + "snapshot-reexport-\(UUID().uuidString)"
            app.imageObjectStore = FilesystemImageObjectStore(rootPath: storeRoot)
            defer { try? FileManager.default.removeItem(atPath: storeRoot) }

            // The transfer route authenticates agent mTLS, whose XFCC trust
            // check needs loopback provenance — bind a real ephemeral port
            // (see artifactUploadAndDownloadRoundTripOverAgentMTLS).
            app.spireService = SPIREService(
                config: SPIREServiceConfig(enabled: true, trustDomain: "strato.local"),
                logger: app.logger, httpClient: app.client)
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let outcome: Result<Void, any Error>
            do {
                let port = try #require(
                    app.http.server.shared.localAddress?.port,
                    "HTTP server did not report a bound port")

                let snapshot = try await seedExportedSnapshot(
                    app: app, user: user, sandbox: sandbox, agentId: "agent-a")
                // Compare stamps that both round-tripped through the
                // database: the in-memory Date carries sub-second precision
                // the datetime column truncates, so comparing it against a
                // later DB read fails spuriously.
                let seeded = try #require(await SandboxSnapshot.find(snapshot.id, on: app.db))
                let exportedAt = try #require(seeded.exportedAt)

                // One artifact of a re-export lands, then the run dies. The
                // snapshot must still be exported: the objects are unchanged
                // and a complete copy is still there.
                let path = SandboxSnapshot.artifactTransferPath(
                    sandboxId: sandbox.id!, snapshotId: snapshot.id!, kind: .memory)
                let response = try await app.client.put(
                    URI(string: "http://127.0.0.1:\(port)\(path)")
                ) { req in
                    req.headers.add(
                        name: "X-Forwarded-Client-Cert",
                        value: "URI=spiffe://strato.local/agent/reexport-agent")
                    req.body = ByteBuffer(string: "fresh-memory-bytes")
                }
                #expect(response.status == .ok)

                let current = try #require(await SandboxSnapshot.find(snapshot.id, on: app.db))
                #expect(current.exportedAt == exportedAt)
                #expect(current.isExported)
                // The integrity entry was still refreshed from the new bytes.
                let memory = try #require(current.exportedArtifact(for: .memory))
                #expect(memory.sizeBytes == Int64("fresh-memory-bytes".utf8.count))
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await app.server.shutdown()
            try outcome.get()
        }
    }
}
