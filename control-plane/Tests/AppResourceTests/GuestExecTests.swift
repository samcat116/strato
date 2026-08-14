import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Tests for the VM/sandbox guest-exec surface: HTTP validation and gating,
/// the `GuestExecSessionManager` pending/attach lifecycle, agent-ownership
/// anti-spoofing, and the sandbox logs endpoint's Loki gating. The
/// browser-attach relay has a separate live-WebSocket integration suite.
@Suite("Guest Exec and Sandbox Log Tests", .serialized)
final class GuestExecTests {

    /// Same harness shape as `SandboxTests`: full middleware stack,
    /// role-binding-backed authorization, API-key auth, one org/project and
    /// one pre-created sandbox.
    private func withSandboxTestApp(
        _ test: (Application, User, Project, Sandbox, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "execuser",
                email: "exec@example.com",
                displayName: "Exec User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Exec Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Exec Project",
                description: "Project for sandbox exec tests",
                organization: org
            )
            let sandbox = try await builder.createSandbox(name: "exec-sandbox", project: project)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, project, sandbox, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// Registers an in-memory agent (current wire protocol) and optionally
    /// maps a workload to it. VM guest exec is opt-in so tests cannot
    /// accidentally model today's bridge-less production agent as capable.
    private func registerAgent(
        app: Application,
        sandbox: Sandbox? = nil,
        vm: VM? = nil,
        named agentName: String = "exec-agent",
        supportsVMGuestExec: Bool? = nil
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: agentName,
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
                    capabilities: .capabilities(for: .qemu),
                    supportsVsock: true,
                    supportsGuestExec: supportsVMGuestExec)
            ],
            protocolVersion: WireProtocol.currentVersion,
            sandboxCapable: true
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: agentName,
            organizationScope: orgID.map { .organization($0) })
        if let sandbox {
            sandbox.hypervisorId = agentUUID.uuidString
            try await sandbox.save(on: app.db)
        }
        if let vm {
            vm.hypervisorId = agentUUID.uuidString
            try await vm.save(on: app.db)
        }
        return agentUUID.uuidString
    }

    private struct ExecBody: Content {
        var command: [String]?
        var env: [String: String]?
        var workingDir: String?
        var tty: Bool?
        var rows: Int?
        var cols: Int?
    }

    // MARK: - POST /api/sandboxes/:id/exec validation

    @Test("POST exec rejects an empty command array")
    func execRejectsEmptyCommand() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/exec") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: []))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("POST exec rejects a body without a command")
    func execRejectsMissingCommand() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/exec") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody())
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("POST exec is rejected (400) while the sandbox is not running")
    func execRejectedWhenNotRunning() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/exec") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: ["/bin/sh"]))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("POST exec is rejected (409) for a running sandbox with no placement")
    func execRejectedWhenUnplaced() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            sandbox.setStatus(.running)
            try await sandbox.save(on: app.db)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/exec") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: ["/bin/sh"]))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("POST exec is rejected (503) when this replica does not hold the agent socket")
    func execUnavailableWithoutLocalSocket() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            // Registered in the database (current protocol) but with no
            // WebSocket in this process's websocketManager — the same shape
            // as the socket living on another replica.
            _ = try await self.registerAgent(app: app, sandbox: sandbox)
            sandbox.setStatus(.running)
            try await sandbox.save(on: app.db)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/exec") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: ["/bin/sh"]))
            } afterResponse: { res in
                #expect(res.status == .serviceUnavailable)
            }
        }
    }

    @Test("POST exec is denied (403) for a viewer (sandbox:exec is operator and above)")
    func execDeniedWithoutPermission() async throws {
        try await withSandboxTestApp { app, _, project, sandbox, _ in
            let viewer = try await TestDataBuilder(db: app.db).createUser(
                username: "exec-viewer", email: "exec-viewer@example.com")
            try await RoleBindingService.grant(
                principalType: .user, principalID: viewer.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)
            let viewerToken = try await viewer.generateAPIKey(on: app.db)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/exec") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: viewerToken)
                try req.content.encode(ExecBody(command: ["/bin/sh"]))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - POST /api/vms/:id/exec validation

    @Test("VM exec is denied (403) without a deliberate vm:exec grant")
    func vmExecDeniedWithoutPermission() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "exec-vm", project: project)

            try await app.test(.POST, "/api/vms/\(vm.id!)/exec") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: ["/bin/sh"]))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("VM exec rejects an empty command array")
    func vmExecRejectsEmptyCommand() async throws {
        try await withSandboxTestApp { app, user, project, _, token in
            user.isSystemAdmin = true
            try await user.save(on: app.db)
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "exec-vm", project: project)

            try await app.test(.POST, "/api/vms/\(vm.id!)/exec") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: []))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("VM exec is rejected (400) while the VM is not running")
    func vmExecRejectedWhenNotRunning() async throws {
        try await withSandboxTestApp { app, user, project, _, token in
            user.isSystemAdmin = true
            try await user.save(on: app.db)
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "exec-vm", project: project)

            try await app.test(.POST, "/api/vms/\(vm.id!)/exec") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: ["/bin/sh"]))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("VM exec is rejected (409) for a running VM with no placement")
    func vmExecRejectedWhenUnplaced() async throws {
        try await withSandboxTestApp { app, user, project, _, token in
            user.isSystemAdmin = true
            try await user.save(on: app.db)
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "exec-vm", project: project)
            vm.guestAgentEnabled = true
            vm.setStatus(.running)
            try await vm.save(on: app.db)

            try await app.test(.POST, "/api/vms/\(vm.id!)/exec") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: ["/bin/sh"]))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("VM exec is rejected (400) when the VM guest agent was not enabled")
    func vmExecRejectedWithoutGuestAgent() async throws {
        try await withSandboxTestApp { app, user, project, _, token in
            user.isSystemAdmin = true
            try await user.save(on: app.db)
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "exec-vm", project: project)
            vm.setStatus(.running)
            try await vm.save(on: app.db)

            try await app.test(.POST, "/api/vms/\(vm.id!)/exec") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: ["/bin/sh"]))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("guest agent enabled"))
            }
        }
    }

    @Test("VM exec is rejected (503) when the assigned agent does not advertise its bridge")
    func vmExecUnavailableWithoutAdvertisedBridge() async throws {
        try await withSandboxTestApp { app, user, project, _, token in
            user.isSystemAdmin = true
            try await user.save(on: app.db)
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "exec-vm", project: project)
            vm.guestAgentEnabled = true
            _ = try await self.registerAgent(app: app, vm: vm)
            vm.setStatus(.running)
            try await vm.save(on: app.db)

            try await app.test(.POST, "/api/vms/\(vm.id!)/exec") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: ["/bin/sh"]))
            } afterResponse: { res in
                #expect(res.status == .serviceUnavailable)
                #expect(res.body.string.contains("does not support VM guest exec"))
            }
        }
    }

    @Test("VM exec is rejected (503) when this replica does not hold the agent socket")
    func vmExecUnavailableWithoutLocalSocket() async throws {
        try await withSandboxTestApp { app, user, project, _, token in
            user.isSystemAdmin = true
            try await user.save(on: app.db)
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "exec-vm", project: project)
            vm.guestAgentEnabled = true
            _ = try await self.registerAgent(app: app, vm: vm, supportsVMGuestExec: true)
            vm.setStatus(.running)
            try await vm.save(on: app.db)

            try await app.test(.POST, "/api/vms/\(vm.id!)/exec") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: ["/bin/sh"]))
            } afterResponse: { res in
                #expect(res.status == .serviceUnavailable)
                #expect(res.body.string.contains("requires the replica holding the agent socket"))
            }
        }
    }

    // MARK: - POST /api/vms/:id/actions/run

    @Test("VM command run is denied without the separate vm:runCommand grant")
    func vmRunDeniedWithoutPermission() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "run-vm", project: project)
            try await app.test(.POST, "/api/vms/\(vm.id!)/actions/run") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: ["/usr/bin/id"]))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            #expect(try await VMCommandExecution.query(on: app.db).count() == 0)
        }
    }

    @Test("VM command run returns a pollable failed operation when socket delivery fails")
    func vmRunReturnsPollableOperation() async throws {
        try await withSandboxTestApp { app, user, project, _, token in
            user.isSystemAdmin = true
            try await user.save(on: app.db)
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "run-vm", project: project)
            vm.guestAgentEnabled = true
            _ = try await self.registerAgent(app: app, vm: vm, supportsVMGuestExec: true)
            vm.setStatus(.running)
            try await vm.save(on: app.db)

            var accepted: OperationResponse?
            try await app.test(.POST, "/api/vms/\(vm.id!)/actions/run") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: ["/usr/bin/id"]))
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(OperationResponse.self)
                #expect(accepted?.kind == .run)
                #expect(accepted?.status == .failed)
                #expect(accepted?.result?.exitCode == nil)
            }

            let operationID = try #require(accepted?.id)
            try await app.test(.GET, "/api/operations/\(operationID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.id == operationID)
                #expect(operation.status == .failed)
                #expect(operation.error?.contains("Could not dispatch command") == true)
            }
        }
    }

    // MARK: - Session manager lifecycle

    private func mintPendingSession(
        _ manager: GuestExecSessionManager,
        resourceKind: GuestResourceKind = .sandbox,
        resourceId: String = UUID().uuidString,
        userId: String = UUID().uuidString,
        now: Date = Date()
    ) -> GuestExecSessionManager.PendingExecSession {
        manager.createPendingSession(
            resourceKind: resourceKind,
            resourceId: resourceId,
            agentKey: agentKey("exec-agent"),
            userId: userId,
            command: ["/bin/sh", "-c", "echo hi"],
            env: ["FOO": "bar"],
            workingDir: "/app",
            tty: true,
            rows: 24,
            cols: 80,
            now: now
        )
    }

    @Test("A pending session carries the exec request and a 60s expiry")
    func pendingSessionShape() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let now = Date()
            let session = self.mintPendingSession(manager, now: now)

            #expect(session.command == ["/bin/sh", "-c", "echo hi"])
            #expect(session.tty == true)
            #expect(session.rows == 24)
            #expect(session.cols == 80)
            let expectedExpiry = now.addingTimeInterval(GuestExecSessionManager.pendingSessionTTL)
            #expect(session.expiresAt == expectedExpiry)
            let exists = manager.hasPendingSession(sessionId: session.sessionId, now: now)
            #expect(exists == true)
        }
    }

    @Test("Pending sessions expire after the TTL and are swept on access")
    func pendingSessionExpires() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let now = Date()
            let session = self.mintPendingSession(manager, now: now)
            let later = now.addingTimeInterval(GuestExecSessionManager.pendingSessionTTL + 1)

            // Attaching after the TTL reports expiry...
            do {
                _ = try manager.attachSession(
                    sessionId: session.sessionId,
                    resourceKind: session.resourceKind,
                    resourceId: session.resourceId,
                    userId: session.userId,
                    websocket: nil,
                    now: later
                )
                Issue.record("Expected sessionExpired to be thrown")
            } catch let error as GuestExecSessionError {
                #expect(error == .sessionExpired(session.sessionId))
            }

            // ...and the entry is gone afterwards.
            let stillThere = manager.hasPendingSession(sessionId: session.sessionId, now: later)
            #expect(stillThere == false)
        }
    }

    @Test("Attach validates the resource kind, resource id, and user the session was minted for")
    func attachValidatesResourceAndUser() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let session = self.mintPendingSession(manager)

            do {
                _ = try manager.attachSession(
                    sessionId: session.sessionId,
                    resourceKind: session.resourceKind,
                    resourceId: UUID().uuidString,
                    userId: session.userId,
                    websocket: nil
                )
                Issue.record("Expected sessionMismatch for a foreign sandbox")
            } catch let error as GuestExecSessionError {
                #expect(error == .sessionMismatch(session.sessionId))
            }

            do {
                _ = try manager.attachSession(
                    sessionId: session.sessionId,
                    resourceKind: .virtualMachine,
                    resourceId: session.resourceId,
                    userId: session.userId,
                    websocket: nil
                )
                Issue.record("Expected sessionMismatch for a different resource kind")
            } catch let error as GuestExecSessionError {
                #expect(error == .sessionMismatch(session.sessionId))
            }

            do {
                _ = try manager.attachSession(
                    sessionId: session.sessionId,
                    resourceKind: session.resourceKind,
                    resourceId: session.resourceId,
                    userId: UUID().uuidString,
                    websocket: nil
                )
                Issue.record("Expected sessionMismatch for a foreign user")
            } catch let error as GuestExecSessionError {
                #expect(error == .sessionMismatch(session.sessionId))
            }

            // A failed attach must not consume the pending session.
            let stillPending = manager.hasPendingSession(sessionId: session.sessionId)
            #expect(stillPending == true)
        }
    }

    @Test("Attach of an unknown session throws sessionNotFound")
    func attachUnknownSession() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let bogus = UUID().uuidString

            do {
                _ = try manager.attachSession(
                    sessionId: bogus,
                    resourceKind: .sandbox,
                    resourceId: UUID().uuidString,
                    userId: UUID().uuidString,
                    websocket: nil
                )
                Issue.record("Expected sessionNotFound")
            } catch let error as GuestExecSessionError {
                #expect(error == .sessionNotFound(bogus))
            }
        }
    }

    @Test("Attach consumes the pending session; a second attach is rejected")
    func duplicateAttachRejected() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let session = self.mintPendingSession(manager)

            let attached = try manager.attachSession(
                sessionId: session.sessionId,
                resourceKind: session.resourceKind,
                resourceId: session.resourceId,
                userId: session.userId,
                websocket: nil
            )
            #expect(attached.command == session.command)
            let pendingAfterAttach = manager.hasPendingSession(sessionId: session.sessionId)
            #expect(pendingAfterAttach == false)
            let info = manager.getSession(sessionId: session.sessionId)
            #expect(info?.resourceKind == session.resourceKind)
            #expect(info?.resourceId == session.resourceId)
            #expect(info?.agentKey == agentKey("exec-agent"))

            do {
                _ = try manager.attachSession(
                    sessionId: session.sessionId,
                    resourceKind: session.resourceKind,
                    resourceId: session.resourceId,
                    userId: session.userId,
                    websocket: nil
                )
                Issue.record("Expected alreadyAttached")
            } catch let error as GuestExecSessionError {
                #expect(error == .alreadyAttached(session.sessionId))
            }

            // The kind-aware resource index tracks the attached session and empties
            // on removal.
            let forResource = manager.getSessions(
                resourceKind: session.resourceKind, resourceId: session.resourceId)
            #expect(forResource.count == 1)
            manager.removeSession(sessionId: session.sessionId)
            let afterRemoval = manager.getSessions(
                resourceKind: session.resourceKind, resourceId: session.resourceId)
            #expect(afterRemoval.isEmpty)
            #expect(manager.getSession(sessionId: session.sessionId) == nil)
        }
    }

    @Test("Terminal agent events only tear down sessions owned by the reporting agent")
    func terminalEventsRequireOwningAgent() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let session = self.mintPendingSession(manager)
            _ = try manager.attachSession(
                sessionId: session.sessionId,
                resourceKind: session.resourceKind,
                resourceId: session.resourceId,
                userId: session.userId,
                websocket: nil
            )

            // A spoofed exit from a different agent must not remove the session.
            manager.handleExit(sessionId: session.sessionId, fromAgentKey: agentKey("impostor"), exitCode: 0)
            #expect(manager.getSession(sessionId: session.sessionId) != nil)

            // The owning agent's exit does.
            manager.handleExit(sessionId: session.sessionId, fromAgentKey: agentKey("exec-agent"), exitCode: 0)
            #expect(manager.getSession(sessionId: session.sessionId) == nil)
        }
    }

    @Test("Agent disconnect tears down that agent's attached and pending sessions")
    func agentDisconnectClosesSessions() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager

            // One attached and one still-pending session for the
            // disconnecting agent...
            let attached = self.mintPendingSession(manager)
            _ = try manager.attachSession(
                sessionId: attached.sessionId,
                resourceKind: attached.resourceKind,
                resourceId: attached.resourceId,
                userId: attached.userId,
                websocket: nil
            )
            let pending = self.mintPendingSession(manager)

            // ...and an attached session on a different agent that must
            // survive the teardown.
            let otherSandboxId = UUID().uuidString
            let otherUserId = UUID().uuidString
            let other = manager.createPendingSession(
                resourceKind: .sandbox,
                resourceId: otherSandboxId,
                agentKey: agentKey("other-agent"),
                userId: otherUserId,
                command: ["/bin/sh"],
                env: nil,
                workingDir: nil,
                tty: false,
                rows: nil,
                cols: nil
            )
            _ = try manager.attachSession(
                sessionId: other.sessionId,
                resourceKind: other.resourceKind,
                resourceId: other.resourceId,
                userId: otherUserId,
                websocket: nil
            )

            manager.closeAllSessions(forAgent: agentKey("exec-agent"), reason: "agent disconnected")

            #expect(manager.getSession(sessionId: attached.sessionId) == nil)
            let attachedIndex = manager.getSessions(
                resourceKind: attached.resourceKind, resourceId: attached.resourceId)
            #expect(attachedIndex.isEmpty)
            let pendingSurvives = manager.hasPendingSession(sessionId: pending.sessionId)
            #expect(pendingSurvives == false)

            // The other agent's session is untouched.
            #expect(manager.getSession(sessionId: other.sessionId) != nil)
        }
    }

    @Test("Input routing for an unattached session throws sessionNotFound")
    func inputRequiresAttachedSession() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let bogus = UUID().uuidString

            do {
                try await manager.routeInput(sessionId: bogus, data: Data([0x6C, 0x73]))
                Issue.record("Expected sessionNotFound")
            } catch let error as GuestExecSessionError {
                #expect(error == .sessionNotFound(bogus))
            }
        }
    }

    // MARK: - Agent ownership (anti-spoofing for sandbox_log)

    @Test("sandboxIsOwnedByAgent accepts the owning agent and rejects others")
    func sandboxOwnershipCheck() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            _ = try await self.registerAgent(app: app, sandbox: sandbox, named: "owner-agent")
            _ = try await self.registerAgent(app: app, named: "other-agent")

            let sandboxId = sandbox.id!.uuidString
            let owned = await app.agentService.sandboxIsOwnedByAgent(
                sandboxId: sandboxId, agentKey: agentKey("owner-agent"))
            #expect(owned == true)

            let foreign = await app.agentService.sandboxIsOwnedByAgent(
                sandboxId: sandboxId, agentKey: agentKey("other-agent"))
            #expect(foreign == false)

            let unknown = await app.agentService.sandboxIsOwnedByAgent(
                sandboxId: UUID().uuidString, agentKey: agentKey("owner-agent"))
            #expect(unknown == false)
        }
    }

    // MARK: - Sandbox logs endpoint

    @Test("GET /api/sandboxes/:id/logs returns [] when Loki is not configured")
    func logsEmptyWithoutLoki() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            try await app.test(.GET, "/api/sandboxes/\(sandbox.id!)/logs") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let entries = try res.content.decode([LogEntry].self)
                #expect(entries.isEmpty)
            }
        }
    }

    @Test("GET /api/sandboxes/:id/logs is denied (403) when no binding grants read")
    func logsDeniedWithoutPermission() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            let outsider = try await TestDataBuilder(db: app.db).createUser(
                username: "logs-outsider", email: "logs-outsider@example.com")
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)

            try await app.test(.GET, "/api/sandboxes/\(sandbox.id!)/logs") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("GET /api/sandboxes/:id/logs rejects an invalid sandbox id")
    func logsRejectsInvalidId() async throws {
        try await withSandboxTestApp { app, _, _, _, token in
            try await app.test(.GET, "/api/sandboxes/not-a-uuid/logs") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }
}
