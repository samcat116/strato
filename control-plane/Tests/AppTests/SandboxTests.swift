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

    /// Registers an in-memory Firecracker-capable agent and maps the sandbox
    /// to it. Returns the agent's UUID string.
    private func registerAgent(
        app: Application,
        sandbox: Sandbox,
        named agentName: String = "sandbox-agent"
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
            protocolVersion: WireProtocol.currentVersion
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: agentName,
            organizationScope: orgID.map { .organization($0) })
        sandbox.hypervisorId = agentUUID.uuidString
        try await sandbox.save(on: app.db)
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
