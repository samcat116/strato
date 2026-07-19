import Testing
import Vapor
import Fluent
import VaporTesting
import StratoShared
@testable import App

/// Tests for the sandbox resource surface (issue #413): `/api/sandboxes` CRUD
/// and lifecycle endpoints return 202-Accepted async operations, mutations
/// write desired state atomically with the operation row, SpiceDB guards the
/// routes through the generalized prefix mapping, desired-state syncs carry
/// sandboxes, and observed-state reports complete operations by generation —
/// all mirroring the VM contracts.
@Suite("Sandbox Tests", .serialized)
final class SandboxTests {

    /// Same harness shape as `VMOperationTests`: full middleware stack, mock
    /// SpiceDB, API-key auth, one org/project and one pre-created sandbox.
    private func withSandboxTestApp(
        _ test: (Application, User, Project, Sandbox, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "sandboxuser",
                email: "sandbox@example.com",
                displayName: "Sandbox User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Sandbox Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Sandbox Project",
                description: "Project for sandbox tests",
                organization: org
            )
            let sandbox = try await builder.createSandbox(name: "test-sandbox", project: project)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, project, sandbox, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// Registers an in-memory Firecracker-capable agent and (optionally) maps
    /// the sandbox to it. Returns the agent's UUID string.
    private func registerAgent(
        app: Application,
        sandbox: Sandbox? = nil,
        named agentName: String = "sandbox-agent",
        sandboxCapable: Bool? = nil,
        protocolVersion: Int? = WireProtocol.currentVersion,
        architecture: CPUArchitecture? = nil
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: agentName,
            hostname: "test-host",
            version: "1.0.0",
            capabilities: ["firecracker"],
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            architecture: architecture,
            protocolVersion: protocolVersion,
            sandboxCapable: sandboxCapable
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: agentName,
            organizationScope: orgID.map { .organization($0) })
        if let sandbox {
            sandbox.hypervisorId = agentUUID.uuidString
            try await sandbox.save(on: app.db)
        }
        return agentUUID.uuidString
    }

    private func report(
        agentId: String,
        sandboxes: [ObservedSandboxState]
    ) throws -> MessageEnvelope {
        let report = ObservedStateReport(
            agentId: agentId,
            vms: [],
            sandboxes: sandboxes,
            resources: AgentResources(
                totalCPU: 16, availableCPU: 12,
                totalMemory: 1 << 34, availableMemory: 1 << 33,
                totalDisk: 1 << 40, availableDisk: 1 << 39
            )
        )
        return try MessageEnvelope(message: report)
    }

    /// Waits for the background task to resolve the sandbox to `expected`.
    /// The operation row and the sandbox row are written separately, so tests
    /// must poll the row they assert on.
    private func pollSandboxStatus(
        _ sandboxID: UUID, until expected: SandboxStatus, on db: any Database
    ) async throws {
        for _ in 0..<100 {
            if let sandbox = try await Sandbox.find(sandboxID, on: db), sandbox.status == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Sandbox \(sandboxID) never reached status \(expected.rawValue)")
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

    // MARK: - Model defaults

    @Test("New sandboxes rest at desired stopped with generation zero")
    func modelDefaults() async throws {
        try await withSandboxTestApp { _, _, _, sandbox, _ in
            #expect(sandbox.status == .stopped)
            #expect(sandbox.desiredStatus == .stopped)
            #expect(sandbox.generation == 0)
            #expect(sandbox.observedGeneration == 0)

            sandbox.setDesiredStatus(.running)
            #expect(sandbox.generation == 1)
        }
    }

    @Test("revertDesiredToObserved leaves a satisfied desired state alone")
    func revertRespectsExited() async throws {
        try await withSandboxTestApp { _, _, _, sandbox, _ in
            // `.exited` satisfies desired `.running`, so a failed unrelated
            // operation must not flip desired to `.stopped`.
            sandbox.setDesiredStatus(.running)
            sandbox.setStatus(.exited)
            #expect(sandbox.revertDesiredToObserved() == false)
            #expect(sandbox.desiredStatus == .running)

            // An unachieved `.absent` (failed delete) reverts to a resting state.
            sandbox.setDesiredStatus(.absent)
            #expect(sandbox.revertDesiredToObserved() == true)
            #expect(sandbox.desiredStatus == .stopped)
        }
    }

    // MARK: - Scheduler gating (issue #415)

    @Test("Registration persists the advertised sandbox capability and its absence clears it")
    func registrationPersistsSandboxCapability() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let agentId = try await registerAgent(app: app, named: "capable-agent", sandboxCapable: true)
            let registered = try await Agent.find(UUID(uuidString: agentId), on: app.db)
            #expect(registered?.sandboxCapable == true)

            // Re-registration without the flag (e.g. the guest image was
            // removed, or the agent was downgraded) must clear it.
            _ = try await registerAgent(app: app, named: "capable-agent", sandboxCapable: nil)
            let reRegistered = try await Agent.find(UUID(uuidString: agentId), on: app.db)
            #expect(reRegistered?.sandboxCapable == false)
        }
    }

    @Test("createSandbox places onto a sandbox-capable agent")
    func createSandboxPlacesOnCapableAgent() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            let agentId = try await registerAgent(app: app, named: "runtime-agent", sandboxCapable: true)

            try await app.agentService.createSandbox(sandbox: sandbox, db: app.db)

            let placed = try await Sandbox.find(sandbox.id, on: app.db)
            #expect(placed?.hypervisorId == agentId)
        }
    }

    @Test("createSandbox refuses a Firecracker fleet that never advertised the runtime")
    func createSandboxRefusesRuntimelessFleet() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            // Firecracker-capable and current protocol, but no sandboxCapable —
            // e.g. a v5 build without the runtime, or no guest image on disk.
            _ = try await registerAgent(app: app, named: "runtimeless-agent", sandboxCapable: nil)

            do {
                try await app.agentService.createSandbox(sandbox: sandbox, db: app.db)
                Issue.record("Expected schedulingFailed error")
            } catch let error as AgentServiceError {
                guard case .schedulingFailed(let reason) = error else {
                    Issue.record("Expected schedulingFailed, got \(error)")
                    return
                }
                #expect(reason.contains("sandbox runtime"))
            }

            let unplaced = try await Sandbox.find(sandbox.id, on: app.db)
            #expect(unplaced?.hypervisorId == nil)
        }
    }

    // MARK: - Create

    @Test("POST /api/sandboxes returns 202 with a pending create operation")
    func createReturnsAccepted() async throws {
        try await withSandboxTestApp { app, user, project, _, token in
            let recorder = SpiceDBMockRecorder()
            app.spicedbMockRecorder = recorder

            var operation: OperationResponse?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "worker",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                operation = try res.content.decode(OperationResponse.self)
            }

            let accepted = try #require(operation)
            #expect(accepted.kind == .create)
            #expect(accepted.resourceKind == .sandbox)

            let sandbox = try #require(await Sandbox.find(accepted.resourceId, on: app.db))
            #expect(sandbox.name == "worker")
            #expect(sandbox.image == "ghcr.io/acme/worker:v3")
            #expect(sandbox.desiredStatus == .stopped)
            #expect(sandbox.generation == 1)
            #expect(sandbox.observedGeneration == 0)

            // Ownership tuples: owner (creator) and project.
            let writes = await recorder.writes.filter { $0.entity == "sandbox" }
            #expect(
                writes.contains(
                    SpiceDBMockRecorder.RelationshipWrite(
                        entity: "sandbox", entityId: accepted.resourceId.uuidString,
                        relation: "owner", subject: "user", subjectId: user.id!.uuidString)))
            #expect(
                writes.contains(
                    SpiceDBMockRecorder.RelationshipWrite(
                        entity: "sandbox", entityId: accepted.resourceId.uuidString,
                        relation: "project", subject: "project", subjectId: project.id!.uuidString)))

            // No schedulable agent exists, so background placement must fail
            // the operation and surface the sandbox as error.
            let completed = try await self.pollOperationCompleted(accepted.id!, on: app.db)
            #expect(completed?.status == .failed)
            try await self.pollSandboxStatus(accepted.resourceId, until: .error, on: app.db)
        }
    }

    @Test("POST /api/sandboxes forks a ready snapshot with new identity and pinned placement")
    func createFromSnapshot() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agentId = try await registerAgent(
                app: app,
                sandbox: source,
                named: "fork-agent",
                sandboxCapable: true,
                architecture: CPUArchitecture.current)

            source.imageDigest = "sha256:" + String(repeating: "a", count: 64)
            source.cpus = 3
            source.memory = 2 * 1024 * 1024 * 1024
            source.entrypoint = ["/usr/bin/worker"]
            source.cmd = ["--serve"]
            source.env = ["MODE": "source"]
            source.workingDir = "/srv"
            try await source.save(on: app.db)

            let sourceNIC = SandboxNetworkInterface(
                sandboxID: source.id!,
                macAddress: "52:54:00:00:00:01")
            try await sourceNIC.save(on: app.db)

            let snapshot = SandboxSnapshot(
                name: "fork-point",
                sandboxID: source.id!,
                projectID: project.id!,
                environment: source.environment,
                agentId: agentId,
                createdByID: user.id!)
            snapshot.status = .ready
            snapshot.architecture = CPUArchitecture.current.rawValue
            snapshot.guestControlProtocolVersion =
                SandboxGuestControlProtocol.currentVersion
            try await snapshot.save(on: app.db)

            var operation: OperationResponse?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "worker-fork",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                operation = try res.content.decode(OperationResponse.self)
            }

            let accepted = try #require(operation)
            let forkID = accepted.resourceId
            var fork = try #require(await Sandbox.find(forkID, on: app.db))
            #expect(fork.restoredFromSnapshotId == snapshot.id)
            #expect(fork.image == source.image)
            #expect(fork.imageDigest == source.imageDigest)
            #expect(fork.cpus == source.cpus)
            #expect(fork.memory == source.memory)
            #expect(fork.entrypoint == source.entrypoint)
            #expect(fork.cmd == source.cmd)
            #expect(fork.env == source.env)
            #expect(fork.workingDir == source.workingDir)
            #expect(fork.desiredStatus == .running)
            #expect(fork.generation == 1)

            for _ in 0..<100 where fork.hypervisorId == nil {
                try await Task.sleep(for: .milliseconds(20))
                fork = try #require(await Sandbox.find(forkID, on: app.db))
            }
            #expect(fork.hypervisorId == agentId)

            let desired = try await app.agentService.assembleDesiredState(agentId: agentId)
            let forkState = try #require(desired.sandboxes.first { $0.sandboxId == forkID })
            let expectedRef = SandboxSnapshotRef(
                snapshotId: snapshot.id!, sourceSandboxId: source.id!)
            #expect(forkState.restoreFrom == expectedRef)
            #expect(forkState.spec.restoreFrom == expectedRef)
            #expect(forkState.registryCredential == nil)

            let forkNIC = try #require(
                await SandboxNetworkInterface.query(on: app.db)
                    .filter(\.$sandbox.$id == forkID)
                    .first())
            #expect(forkNIC.macAddress != sourceNIC.macAddress)
            #expect(forkNIC.deviceName == "net0")
        }
    }

    @Test("Fork refuses machine overrides and an agent below wire v12")
    func createFromSnapshotGuards() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let oldAgent = try await registerAgent(
                app: app,
                sandbox: source,
                named: "old-fork-agent",
                sandboxCapable: true,
                protocolVersion: WireProtocol.sandboxForkMinimumVersion - 1)
            let snapshot = SandboxSnapshot(
                name: "old-agent-checkpoint",
                sandboxID: source.id!,
                projectID: project.id!,
                environment: source.environment,
                agentId: oldAgent,
                createdByID: user.id!)
            snapshot.status = .ready
            try await snapshot.save(on: app.db)

            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "invalid-fork",
                    "restoreFrom": snapshot.id!.uuidString,
                    "image": "docker.io/library/alpine:latest",
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "old-agent-fork",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("too old"))
            }
        }
    }

    @Test("Fork refuses a checkpoint whose guest predates re-identification")
    func createFromSnapshotRejectsLegacyGuest() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agentId = try await registerAgent(
                app: app,
                sandbox: source,
                named: "current-agent-with-legacy-guest",
                sandboxCapable: true)
            let snapshot = SandboxSnapshot(
                name: "legacy-guest-checkpoint",
                sandboxID: source.id!,
                projectID: project.id!,
                environment: source.environment,
                agentId: agentId,
                createdByID: user.id!)
            snapshot.status = .ready
            snapshot.guestControlProtocolVersion =
                SandboxGuestControlProtocol.reidentifyMinimumVersion - 1
            try await snapshot.save(on: app.db)

            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "unsafe-fork",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("checkpointed guest is too old"))
            }
        }
    }

    @Test("Fork transaction rechecks destructive source transitions")
    func createFromSnapshotRechecksLineage() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agentId = try await registerAgent(
                app: app,
                sandbox: source,
                named: "lineage-lock-agent",
                sandboxCapable: true)
            let snapshot = SandboxSnapshot(
                name: "lineage-lock-checkpoint",
                sandboxID: source.id!,
                projectID: project.id!,
                environment: source.environment,
                agentId: agentId,
                createdByID: user.id!)
            snapshot.status = .ready
            snapshot.guestControlProtocolVersion =
                SandboxGuestControlProtocol.currentVersion
            try await snapshot.save(on: app.db)

            source.desiredStatus = .absent
            try await source.save(on: app.db)
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "fork-during-source-delete",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("source sandbox is being deleted"))
            }

            source.desiredStatus = .running
            try await source.save(on: app.db)
            let restore = ResourceOperation(
                sandboxID: source.id!, userID: user.id!, kind: .restore)
            try await restore.save(on: app.db)
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "fork-during-source-restore",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("being restored in place"))
            }
        }
    }

    @Test("POST /api/sandboxes rejects an empty image reference")
    func createRejectsEmptyImage() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "worker",
                    "image": "   ",
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - Lifecycle: 202 + dispatch failure recording

    @Test("POST /api/sandboxes/:id/start returns 202 and fails fast without an agent")
    func startFailsFastWithoutAgent() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            var operationId: UUID?

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.kind == .boot)
                #expect(operation.status == .pending)
                #expect(operation.resourceId == sandbox.id)
                operationId = operation.id
            }

            // No agent is mapped, so the background dispatch fails
            // immediately and realigns desired state with observed.
            let operation = try await self.pollOperationCompleted(operationId!, on: app.db)
            #expect(operation?.status == .failed)
            #expect(operation?.error?.isEmpty == false)

            for _ in 0..<100 {
                if let refreshed = try await Sandbox.find(sandbox.id, on: app.db),
                    refreshed.desiredStatus == .stopped
                {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let refreshed = try await Sandbox.find(sandbox.id, on: app.db)
            #expect(refreshed?.desiredStatus == .stopped)
        }
    }

    @Test("POST start is rejected (400) while the sandbox is running")
    func startRejectedWhileRunning() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            sandbox.setStatus(.running)
            try await sandbox.save(on: app.db)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("A second mutation while one is pending is rejected with 409")
    func conflictingOperationRejected() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, token in
            // Running, so the stop below passes its state guard and reaches
            // the double-submit check.
            sandbox.setStatus(.running)
            try await sandbox.save(on: app.db)

            // Pin a pending operation directly so no background completion races it.
            let pending = ResourceOperation(
                sandboxID: sandbox.id!, userID: user.id!, kind: .boot)
            try await pending.save(on: app.db)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/stop") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("DELETE without an agent removes the record and succeeds the operation")
    func deleteWithoutAgentRemovesRecord() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            var operationId: UUID?
            try await app.test(.DELETE, "/api/sandboxes/\(sandbox.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                operationId = try res.content.decode(OperationResponse.self).id
            }

            let operation = try await self.pollOperationCompleted(operationId!, on: app.db)
            #expect(operation?.status == .succeeded)
            let gone = try await Sandbox.find(sandbox.id, on: app.db)
            #expect(gone == nil)
        }
    }

    @Test("GET /api/operations/:id resolves sandbox operations")
    func operationVisibility() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, token in
            let operation = ResourceOperation(
                sandboxID: sandbox.id!, userID: user.id!, kind: .boot)
            try await operation.save(on: app.db)

            try await app.test(.GET, "/api/operations/\(operation.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(OperationResponse.self)
                #expect(decoded.resourceKind == .sandbox)
                #expect(decoded.resourceId == sandbox.id)
            }
        }
    }

    @Test("DELETE /api/projects/:id is rejected (409) while sandboxes exist")
    func projectDeleteBlockedBySandboxes() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            // The sandboxes table references projects, so without the
            // dependent-resource check this would surface as a raw database
            // constraint failure instead of a deterministic conflict.
            try await app.test(.DELETE, "/api/projects/\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("Environment removal is rejected (409) while sandboxes use it")
    func environmentRemovalBlockedBySandboxes() async throws {
        try await withSandboxTestApp { app, _, project, sandbox, token in
            // Move the sandbox off the default environment so the requests
            // below reach the sandbox guard (the default is unremovable, and
            // no VMs exist to trip the VM guard first).
            sandbox.environment = "staging"
            try await sandbox.save(on: app.db)

            try await app.test(.DELETE, "/api/projects/\(project.id!)/environments/staging") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            struct UpdateProjectRequest: Content {
                let environments: [String]
            }
            try await app.test(.PUT, "/api/projects/\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateProjectRequest(environments: ["development", "production"]))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    // MARK: - Authorization

    @Test("GET /api/sandboxes/:id is denied (403) when SpiceDB withholds read")
    func showDeniedWhenNoPermission() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            app.spicedbMockAllows = false

            try await app.test(.GET, "/api/sandboxes/\(sandbox.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("POST /api/sandboxes/:id/start is denied (403) when SpiceDB withholds start")
    func startDeniedWhenNoPermission() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            app.spicedbMockAllows = false

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("GET /api/sandboxes/:id succeeds and carries the sandbox shape")
    func showAllowedWhenPermitted() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            try await app.test(.GET, "/api/sandboxes/\(sandbox.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let detail = try res.content.decode(SandboxDetailResponse.self)
                #expect(detail.image == "ghcr.io/acme/worker:v1")
                #expect(detail.status == .stopped)
            }
        }
    }

    // MARK: - Desired-state sync assembly

    @Test("assembleDesiredState carries the agent's sandboxes")
    func assemblyIncludesSandboxes() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            sandbox.setDesiredStatus(.running)
            try await sandbox.save(on: app.db)

            let message = try await app.agentService.assembleDesiredState(agentId: agentId)
            #expect(message.sandboxes.count == 1)
            let entry = try #require(message.sandboxes.first)
            #expect(entry.sandboxId == sandbox.id)
            #expect(entry.desiredStatus == .running)
            #expect(entry.generation == sandbox.generation)
            #expect(entry.spec.image == "ghcr.io/acme/worker:v1")
            #expect(entry.spec.cpus == 1)
            #expect(entry.registryCredential == nil)
        }
    }

    // MARK: - NIC + IPAM integration (issue #416)

    /// The default logical network the app seeds at migration time
    /// (`192.168.1.0/24`, gateway `.1`, v4-only) — the network the sandbox
    /// create path attaches to.
    private func defaultNetwork(on db: any Database) async throws -> LogicalNetwork {
        try #require(
            await LogicalNetwork.query(on: db)
                .filter(\.$name == LogicalNetwork.defaultNetworkName)
                .first())
    }

    @Test("Creating a sandbox allocates one NIC with an IPv4 address on the default network")
    func createAllocatesNIC() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            var operation: OperationResponse?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "netbox",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                operation = try res.content.decode(OperationResponse.self)
            }

            let sandboxID = try #require(operation).resourceId
            let interfaces = try await SandboxNetworkInterface.query(on: app.db)
                .filter(\.$sandbox.$id == sandboxID)
                .with(\.$addresses)
                .all()
            #expect(interfaces.count == 1)
            let nic = try #require(interfaces.first)
            #expect(nic.network == LogicalNetwork.defaultNetworkName)
            #expect(nic.deviceName == "net0")
            #expect(nic.macAddress.hasPrefix("00:0c:29:"))

            let v4 = try #require(nic.ipv4Address)
            #expect(v4.address == "192.168.1.2")  // .1 is the gateway
            #expect(v4.gateway == "192.168.1.1")
            #expect(v4.prefixLength == 24)
        }
    }

    @Test("A missing default network degrades to an address-less NIC")
    func createDegradesWithoutNetwork() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            // Remove the seeded default network so the create path has no subnet
            // to allocate from and must degrade to an address-less NIC.
            try await LogicalNetwork.query(on: app.db)
                .filter(\.$name == LogicalNetwork.defaultNetworkName)
                .delete()

            var operation: OperationResponse?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "netless",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                operation = try res.content.decode(OperationResponse.self)
            }

            let sandboxID = try #require(operation).resourceId
            let interfaces = try await SandboxNetworkInterface.query(on: app.db)
                .filter(\.$sandbox.$id == sandboxID)
                .with(\.$addresses)
                .all()
            #expect(interfaces.count == 1)
            #expect(try #require(interfaces.first).addresses.isEmpty)
        }
    }

    @Test("IPAM's used set unions VM and sandbox addresses on the same network")
    func ipamUnionsVMAndSandboxAddresses() async throws {
        try await withSandboxTestApp { app, _, project, sandbox, _ in
            let network = try await self.defaultNetwork(on: app.db)

            // A VM holds .2 and a sandbox holds .3 on the same network. The next
            // allocation must skip both — proving the used set unions the two
            // address tables.
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "peer-vm", project: project)
            let vmNIC = VMNetworkInterface(
                vmID: try vm.requireID(), network: network.name,
                macAddress: VMNetworkInterface.generateMACAddress())
            try await vmNIC.save(on: app.db)
            try await VMInterfaceAddress(
                interfaceID: try vmNIC.requireID(), network: network.name, family: .ipv4,
                address: "192.168.1.2", prefixLength: 24, gateway: network.gateway
            ).save(on: app.db)

            let sbNIC = SandboxNetworkInterface(
                sandboxID: try sandbox.requireID(), network: network.name,
                macAddress: VMNetworkInterface.generateMACAddress())
            try await sbNIC.save(on: app.db)
            try await SandboxInterfaceAddress(
                interfaceID: try sbNIC.requireID(), network: network.name, family: .ipv4,
                address: "192.168.1.3", prefixLength: 24, gateway: network.gateway
            ).save(on: app.db)

            let allocation = try await IPAMService.allocateIP(for: network, on: app.db)
            #expect(allocation.ipAddress == "192.168.1.4")
        }
    }

    @Test("assembleDesiredState omits the NIC from the wire spec until guest networking lands")
    func assemblyOmitsNICSpec() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            let network = try await self.defaultNetwork(on: app.db)
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            // Attach a NIC with an allocated address directly.
            let nic = SandboxNetworkInterface(
                sandboxID: try sandbox.requireID(), network: network.name,
                macAddress: "00:0c:29:ab:cd:ef")
            try await nic.save(on: app.db)
            try await SandboxInterfaceAddress(
                interfaceID: try nic.requireID(), network: network.name, family: .ipv4,
                address: "192.168.1.7", prefixLength: 24, gateway: network.gateway
            ).save(on: app.db)

            // The v1 guest image has no in-guest networking and agents reject
            // networked sandbox specs, so the NIC row must stay off the wire
            // even when it holds an address.
            let message = try await app.agentService.assembleDesiredState(agentId: agentId)
            let entry = try #require(message.sandboxes.first)
            #expect(entry.spec.network == nil)

            // The sandbox's network is still realized on its host (scope
            // computation is unchanged), ready for when guest networking lands.
            #expect(message.networks.contains { $0.name == network.name })
        }
    }

    @Test("A freshly created sandbox's wire spec has no network, so it can boot")
    func createdSandboxWireSpecHasNoNetwork() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            var operation: OperationResponse?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "bootable",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                operation = try res.content.decode(OperationResponse.self)
            }
            let sandboxID = try #require(operation).resourceId
            // Drain the background placement attempt (it fails — no
            // sandbox-capable agent is registered yet) so its save cannot race
            // the manual placement below.
            _ = try await self.pollOperationCompleted(try #require(operation).id!, on: app.db)
            let created = try #require(await Sandbox.find(sandboxID, on: app.db))
            let agentId = try await self.registerAgent(app: app, sandbox: created)

            // The end-to-end contract with the v1 agent runtimes: both
            // FirecrackerSandboxRuntime and MockSandboxRuntime throw
            // `networkingUnsupported` for any spec with a non-nil network, so a
            // freshly created sandbox converges only if its wire spec carries
            // none.
            let message = try await app.agentService.assembleDesiredState(agentId: agentId)
            let entry = try #require(message.sandboxes.first { $0.sandboxId == sandboxID })
            #expect(entry.spec.network == nil)

            // The create path still reserved the NIC and its address —
            // control-plane-side only, stable for when guest networking lands.
            let nic = try #require(
                await SandboxNetworkInterface.query(on: app.db)
                    .filter(\.$sandbox.$id == sandboxID)
                    .with(\.$addresses)
                    .first())
            #expect(nic.ipv4Address != nil)
        }
    }

    @Test("Deleting a sandbox cascades its NIC and address rows")
    func deleteCascadesNIC() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            var operation: OperationResponse?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "doomed",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                operation = try res.content.decode(OperationResponse.self)
            }
            let sandboxID = try #require(operation).resourceId

            // Sanity: rows exist before deletion.
            let nicIDs = try await SandboxNetworkInterface.query(on: app.db)
                .filter(\.$sandbox.$id == sandboxID).all().map { try $0.requireID() }
            #expect(nicIDs.count == 1)

            let sandbox = try #require(await Sandbox.find(sandboxID, on: app.db))
            try await sandbox.delete(on: app.db)

            let remainingNICs = try await SandboxNetworkInterface.query(on: app.db)
                .filter(\.$sandbox.$id == sandboxID).count()
            #expect(remainingNICs == 0)
            let remainingAddresses = try await SandboxInterfaceAddress.query(on: app.db)
                .filter(\.$interface.$id ~~ nicIDs).count()
            #expect(remainingAddresses == 0)
        }
    }

    // MARK: - Observed-state reports

    @Test("A converged observation completes the pending boot operation")
    func observedRunningCompletesBoot() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            sandbox.setDesiredStatus(.running)
            try await sandbox.save(on: app.db)
            let operation = ResourceOperation(
                sandboxID: sandbox.id!, userID: user.id!, kind: .boot)
            try await operation.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                sandboxes: [
                    ObservedSandboxState(
                        sandboxId: sandbox.id!, status: .running,
                        observedGeneration: sandbox.generation)
                ])
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "sandbox-agent")

            let refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(refreshed.status == .running)
            #expect(refreshed.observedGeneration == sandbox.generation)

            let completed = try #require(await ResourceOperation.find(operation.id, on: app.db))
            #expect(completed.status == .succeeded)
        }
    }

    @Test("An exited observation satisfies desired running and records the exit code")
    func observedExitedSatisfiesRunning() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            sandbox.setDesiredStatus(.running)
            try await sandbox.save(on: app.db)
            let operation = ResourceOperation(
                sandboxID: sandbox.id!, userID: user.id!, kind: .boot)
            try await operation.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                sandboxes: [
                    ObservedSandboxState(
                        sandboxId: sandbox.id!, status: .exited,
                        observedGeneration: sandbox.generation, exitCode: 0)
                ])
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "sandbox-agent")

            let refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(refreshed.status == .exited)
            #expect(refreshed.exitCode == 0)

            let completed = try #require(await ResourceOperation.find(operation.id, on: app.db))
            #expect(completed.status == .succeeded)
        }
    }

    @Test("A failed convergence at the current generation fails the operation and reverts desired")
    func observedFailureFailsOperation() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            sandbox.setDesiredStatus(.running)
            try await sandbox.save(on: app.db)
            let generation = sandbox.generation
            let operation = ResourceOperation(
                sandboxID: sandbox.id!, userID: user.id!, kind: .boot)
            try await operation.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                sandboxes: [
                    ObservedSandboxState(
                        sandboxId: sandbox.id!, status: .stopped,
                        observedGeneration: 0,
                        lastError: "image pull failed",
                        failedGeneration: generation)
                ])
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "sandbox-agent")

            let completed = try #require(await ResourceOperation.find(operation.id, on: app.db))
            #expect(completed.status == .failed)
            #expect(completed.error == "image pull failed")

            let refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(refreshed.desiredStatus == .stopped)
        }
    }

    @Test("Absence from the report confirms a pending deletion and removes the row")
    func absenceConfirmsDeletion() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            sandbox.setDesiredStatus(.absent)
            try await sandbox.save(on: app.db)
            let operation = ResourceOperation(
                sandboxID: sandbox.id!, userID: user.id!, kind: .delete)
            try await operation.save(on: app.db)

            let envelope = try self.report(agentId: agentId, sandboxes: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "sandbox-agent")

            let completed = try #require(await ResourceOperation.find(operation.id, on: app.db))
            #expect(completed.status == .succeeded)
            let gone = try await Sandbox.find(sandbox.id, on: app.db)
            #expect(gone == nil)
        }
    }

    @Test("Absence does not escalate a never-confirmed sandbox")
    func absenceToleratesUnconfirmedCreate() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            // Mid-create: desired stopped at generation 1, never confirmed.
            sandbox.setDesiredStatus(.stopped)
            try await sandbox.save(on: app.db)

            let envelope = try self.report(agentId: agentId, sandboxes: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "sandbox-agent")

            let refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(refreshed.status == .stopped)
        }
    }

    @Test("Absence escalates an established sandbox to error")
    func absenceEscalatesEstablishedSandbox() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            sandbox.setDesiredStatus(.running)
            sandbox.setStatus(.running)
            sandbox.observedGeneration = sandbox.generation
            try await sandbox.save(on: app.db)

            let envelope = try self.report(agentId: agentId, sandboxes: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "sandbox-agent")

            let refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(refreshed.status == .error)
        }
    }

    // MARK: - Stuck-operation sweep

    @Test("The sweep fails a stuck sandbox create past its budget and resolves the sandbox")
    func sweepResolvesStuckCreate() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, _ in
            sandbox.setDesiredStatus(.stopped)
            try await sandbox.save(on: app.db)

            let operation = ResourceOperation(
                sandboxID: sandbox.id!, userID: user.id!, kind: .create)
            try await operation.save(on: app.db)
            // Backdate past the create budget so the sweep sees it as stuck.
            operation.createdAt = Date(timeIntervalSinceNow: -700)
            try await operation.save(on: app.db)

            await app.agentService.sweepStuckOperations()

            let swept = try #require(await ResourceOperation.find(operation.id, on: app.db))
            #expect(swept.status == .failed)

            let refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(refreshed.status == .error)
        }
    }
}
