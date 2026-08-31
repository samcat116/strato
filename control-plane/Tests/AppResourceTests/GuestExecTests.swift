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
        let project = try #require(try await Project.query(on: app.db).sort(\.$createdAt).first())
        let siteID = try await TestDataBuilder(db: app.db).placementSite(for: project).requireID()
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: agentName, siteID: siteID,
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

    enum AuditedVMGuestExecutionRoute: CaseIterable, Sendable {
        case exec
        case run

        var suffix: String {
            switch self {
            case .exec: "exec"
            case .run: "actions/run"
            }
        }

        var domainRequestEvent: String {
            switch self {
            case .exec: "vm.exec.requested"
            case .run: "vm.command.requested"
            }
        }
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
            let path = "/api/vms/\(vm.id!.uuidString.lowercased())/exec"

            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: ["/bin/sh"]))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            let apiRequests = try await self.auditEvents(ofType: "api.request", on: app)
            #expect(apiRequests.count == 1)
            let apiRequest = try #require(apiRequests.first)
            #expect(apiRequest.path == path)
            #expect(apiRequest.status == 403)
            #expect(apiRequest.resourceType == "vms")
            #expect(apiRequest.resourceID == vm.id?.uuidString)
            #expect(apiRequest.action == "exec")
            #expect(try await self.auditEvents(ofType: "vm.exec.requested", on: app).isEmpty)
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

    @Test("VM exec rejects an oversized command argument before acceptance")
    func vmExecRejectsOversizedCommandArgument() async throws {
        try await withSandboxTestApp { app, user, project, _, token in
            user.isSystemAdmin = true
            try await user.save(on: app.db)
            let vm = try await TestDataBuilder(db: app.db).createVM(
                name: "oversized-exec-vm", project: project)
            let path = "/api/vms/\(vm.id!.uuidString.lowercased())/exec"
            let oversizedArgument = String(repeating: "x", count: Validate.textLength + 1)

            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: [oversizedArgument]))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let requests = try await self.auditEvents(ofType: "api.request", on: app)
            #expect(requests.count == 1)
            #expect(requests.first?.status == 400)
            #expect(requests.first?.metadata == nil)
            #expect(try await self.auditEvents(ofType: "vm.exec.requested", on: app).isEmpty)
        }
    }

    @Test(
        "Invalid VM guest-execution environment is status-only in generic audit",
        arguments: AuditedVMGuestExecutionRoute.allCases)
    func invalidGuestExecutionEnvironmentIsRedacted(
        route: AuditedVMGuestExecutionRoute
    ) async throws {
        try await withSandboxTestApp { app, user, project, _, token in
            user.isSystemAdmin = true
            try await user.save(on: app.db)
            let vm = try await TestDataBuilder(db: app.db).createVM(
                name: "redacted-exec-vm", project: project)
            vm.guestAgentEnabled = true
            _ = try await self.registerAgent(
                app: app, vm: vm, supportsVMGuestExec: true)
            vm.setStatus(.running)
            try await vm.save(on: app.db)

            let keySentinel = "STR84_ENV_KEY_MUST_NOT_REACH_AUDIT"
            let valueSentinel = "STR84_ENV_VALUE_MUST_NOT_REACH_AUDIT"
            let overlongValue =
                valueSentinel + String(repeating: "x", count: Validate.textLength + 1)
            let path = "/api/vms/\(vm.id!.uuidString.lowercased())/\(route.suffix)"

            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ExecBody(
                        command: ["/usr/bin/id"],
                        env: [keySentinel: overlongValue]))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let requests = try await self.auditEvents(ofType: "api.request", on: app)
            #expect(requests.count == 1)
            let request = try #require(requests.first)
            #expect(request.path == path)
            #expect(request.status == 400)
            #expect(request.resourceType == "vms")
            #expect(request.resourceID == vm.id?.uuidString)
            #expect(request.action == route.suffix)
            #expect(request.metadata == nil)
            let persistedMetadata = request.metadataJSON ?? ""
            #expect(!persistedMetadata.contains(keySentinel))
            #expect(!persistedMetadata.contains(valueSentinel))
            #expect(
                try await self.auditEvents(ofType: route.domainRequestEvent, on: app).isEmpty)
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
            let path = "/api/vms/\(vm.id!.uuidString.lowercased())/actions/run"
            try await app.test(.POST, path) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ExecBody(command: ["/usr/bin/id"]))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            #expect(try await VMCommandExecution.query(on: app.db).count() == 0)

            let apiRequests = try await self.auditEvents(ofType: "api.request", on: app)
            #expect(apiRequests.count == 1)
            let apiRequest = try #require(apiRequests.first)
            #expect(apiRequest.path == path)
            #expect(apiRequest.status == 403)
            #expect(apiRequest.resourceType == "vms")
            #expect(apiRequest.resourceID == vm.id?.uuidString)
            #expect(apiRequest.action == "actions/run")
            #expect(
                try await self.auditEvents(ofType: "vm.command.requested", on: app).isEmpty)
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

            let environmentSentinel = "STR84_ENVIRONMENT_MUST_NOT_BE_AUDITED"
            let workingDirectorySentinel = "/STR84/WORKING_DIRECTORY_MUST_NOT_BE_AUDITED"
            var accepted: OperationResponse?
            try await app.test(.POST, "/api/vms/\(vm.id!)/actions/run") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ExecBody(
                        command: ["/usr/bin/id"],
                        env: ["STR84_SECRET": environmentSentinel],
                        workingDir: workingDirectorySentinel))
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(OperationResponse.self)
                #expect(accepted?.kind == .run)
                #expect(accepted?.status == .failed)
                #expect(accepted?.result?.exitCode == nil)
            }

            let operationID = try #require(accepted?.id)
            let payload = try #require(try await VMCommandPayload.find(operationID, on: app.db))
            #expect(payload.command == ["/usr/bin/id"])

            let requested = try #require(
                try await self.auditEvents(ofType: "vm.command.requested", on: app).first)
            #expect(requested.resourceType == "vms")
            #expect(requested.resourceID == vm.id?.uuidString)
            #expect(requested.userID == user.id)
            #expect(requested.metadata?["correlationID"] == operationID.uuidString)
            #expect(requested.metadata?["argv"] == "[\"/usr/bin/id\"]")
            #expect(requested.metadata?["outcome"] == "accepted")
            #expect(!requested.metadata!.values.contains(environmentSentinel))
            #expect(!requested.metadata!.values.contains(workingDirectorySentinel))

            let completed = try #require(
                try await self.auditEvents(ofType: "vm.command.completed", on: app).first)
            #expect(completed.metadata?["correlationID"] == operationID.uuidString)
            #expect(completed.metadata?["outcome"] == "failed")
            #expect(completed.metadata?["reason"]?.contains("Could not dispatch command") == true)
            #expect(!completed.metadata!.values.contains(environmentSentinel))
            #expect(!completed.metadata!.values.contains(workingDirectorySentinel))

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
        sessionId: String = UUID().uuidString,
        resourceKind: GuestResourceKind = .sandbox,
        resourceId: String = UUID().uuidString,
        userId: String = UUID().uuidString,
        auditContext: VMGuestExecutionAuditContext? = nil,
        now: Date = Date()
    ) -> GuestExecSessionManager.PendingExecSession {
        manager.createPendingSession(
            sessionId: sessionId,
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
            auditContext: auditContext,
            now: now
        )
    }

    private func vmAuditContext(
        vmID: UUID,
        sessionId: String,
        userID: UUID = UUID()
    ) -> VMGuestExecutionAuditContext {
        VMGuestExecutionAuditContext(
            vmID: vmID,
            organizationID: UUID(),
            userID: userID,
            username: "exec-auditor",
            apiKeyID: UUID(),
            sourceIP: "192.0.2.84",
            adminBypass: false,
            correlationID: sessionId,
            argv: ["/bin/sh", "-c", "echo hi"])
    }

    private func auditEvents(
        ofType type: String,
        on app: Application
    ) async throws -> [AuditEvent] {
        await app.audit.flush()
        return try await AuditEvent.query(on: app.db)
            .filter(\.$eventType == type)
            .sort(\.$createdAt)
            .all()
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
            let vmID = UUID()
            let sessionId = UUID().uuidString
            let session = self.mintPendingSession(
                manager,
                sessionId: sessionId,
                resourceKind: .virtualMachine,
                resourceId: vmID.uuidString,
                auditContext: self.vmAuditContext(vmID: vmID, sessionId: sessionId),
                now: now)
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
            #expect(try await self.auditEvents(ofType: "vm.exec.started", on: app).isEmpty)
            #expect(try await self.auditEvents(ofType: "vm.exec.ended", on: app).isEmpty)
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
            await manager.endSession(
                sessionId: session.sessionId,
                outcome: .terminated,
                reason: "test cleanup")
            let afterRemoval = manager.getSessions(
                resourceKind: session.resourceKind, resourceId: session.resourceId)
            #expect(afterRemoval.isEmpty)
            #expect(manager.getSession(sessionId: session.sessionId) == nil)
        }
    }

    @Test("Only the first owning-agent start is audited")
    func firstOwningAgentStartIsAuditedOnce() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let vmID = UUID()
            let sessionId = UUID().uuidString
            let session = self.mintPendingSession(
                manager,
                sessionId: sessionId,
                resourceKind: .virtualMachine,
                resourceId: vmID.uuidString,
                auditContext: self.vmAuditContext(vmID: vmID, sessionId: sessionId))
            _ = try manager.attachSession(
                sessionId: session.sessionId,
                resourceKind: session.resourceKind,
                resourceId: session.resourceId,
                userId: session.userId,
                websocket: nil)

            await manager.handleStarted(
                sessionId: session.sessionId, fromAgentKey: agentKey("impostor"))
            #expect(try await self.auditEvents(ofType: "vm.exec.started", on: app).isEmpty)

            await manager.handleStarted(
                sessionId: session.sessionId, fromAgentKey: agentKey("exec-agent"))
            await manager.handleStarted(
                sessionId: session.sessionId, fromAgentKey: agentKey("exec-agent"))

            let events = try await self.auditEvents(ofType: "vm.exec.started", on: app)
            #expect(events.count == 1)
            #expect(events.first?.resourceType == "vms")
            #expect(events.first?.resourceID == vmID.uuidString)
            #expect(events.first?.metadata?["correlationID"] == sessionId)
            #expect(events.first?.metadata?["outcome"] == "started")
        }
    }

    @Test("Concurrent start and end transitions retain lifecycle timestamp order")
    func concurrentStartAndEndTimestampsAreOrdered() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let vmID = UUID()
            let sessionId = UUID().uuidString
            let session = self.mintPendingSession(
                manager,
                sessionId: sessionId,
                resourceKind: .virtualMachine,
                resourceId: vmID.uuidString,
                auditContext: self.vmAuditContext(vmID: vmID, sessionId: sessionId))
            _ = try manager.attachSession(
                sessionId: session.sessionId,
                resourceKind: session.resourceKind,
                resourceId: session.resourceId,
                userId: session.userId,
                websocket: nil)

            // Give both concurrent transitions the same observed wall-clock
            // value. The terminal claim waits only for the locked start state,
            // not its asynchronous audit enqueue, reproducing the ordering
            // race while making the expected one-microsecond floor exact.
            let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await manager.handleStarted(
                        sessionId: session.sessionId,
                        fromAgentKey: agentKey("exec-agent"),
                        timestamp: observedAt)
                }
                group.addTask {
                    while manager.getSession(sessionId: session.sessionId)?
                        .agentConfirmedStartedAt == nil
                    {
                        await Task.yield()
                    }
                    await manager.handleExit(
                        sessionId: session.sessionId,
                        fromAgentKey: agentKey("exec-agent"),
                        exitCode: 0,
                        timestamp: observedAt)
                }
            }

            let started = try #require(
                try await self.auditEvents(ofType: "vm.exec.started", on: app).first)
            let ended = try #require(
                try await self.auditEvents(ofType: "vm.exec.ended", on: app).first)
            let startedAt = try #require(started.createdAt)
            let endedAt = try #require(ended.createdAt)
            #expect(started.metadata?["correlationID"] == sessionId)
            #expect(ended.metadata?["correlationID"] == sessionId)
            #expect(startedAt == observedAt)
            #expect(endedAt > startedAt)
        }
    }

    @Test("Terminal agent events only tear down sessions owned by the reporting agent")
    func terminalEventsRequireOwningAgent() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let vmID = UUID()
            let sessionId = UUID().uuidString
            let session = self.mintPendingSession(
                manager,
                sessionId: sessionId,
                resourceKind: .virtualMachine,
                resourceId: vmID.uuidString,
                auditContext: self.vmAuditContext(vmID: vmID, sessionId: sessionId))
            _ = try manager.attachSession(
                sessionId: session.sessionId,
                resourceKind: session.resourceKind,
                resourceId: session.resourceId,
                userId: session.userId,
                websocket: nil
            )

            // A spoofed exit from a different agent must not remove the session.
            await manager.handleExit(
                sessionId: session.sessionId,
                fromAgentKey: agentKey("impostor"),
                exitCode: 0)
            #expect(manager.getSession(sessionId: session.sessionId) != nil)

            // The owning agent's exit does.
            await manager.handleExit(
                sessionId: session.sessionId,
                fromAgentKey: agentKey("exec-agent"),
                exitCode: 17)
            #expect(manager.getSession(sessionId: session.sessionId) == nil)

            // A duplicate terminal frame arrives after the atomic removal and
            // cannot append a second end fact.
            await manager.handleExit(
                sessionId: session.sessionId,
                fromAgentKey: agentKey("exec-agent"),
                exitCode: 17)

            let events = try await self.auditEvents(ofType: "vm.exec.ended", on: app)
            #expect(events.count == 1)
            #expect(events.first?.resourceID == vmID.uuidString)
            #expect(events.first?.metadata?["correlationID"] == sessionId)
            #expect(events.first?.metadata?["outcome"] == "exited")
            #expect(events.first?.metadata?["exitCode"] == "17")
        }
    }

    @Test("Agent closure is refused before start and disconnected after start")
    func agentClosureUsesConfirmedStartPhase() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let vmID = UUID()

            let refusedSessionId = UUID().uuidString
            let refused = self.mintPendingSession(
                manager,
                sessionId: refusedSessionId,
                resourceKind: .virtualMachine,
                resourceId: vmID.uuidString,
                auditContext: self.vmAuditContext(vmID: vmID, sessionId: refusedSessionId))
            _ = try manager.attachSession(
                sessionId: refused.sessionId,
                resourceKind: refused.resourceKind,
                resourceId: refused.resourceId,
                userId: refused.userId,
                websocket: nil)

            let disconnectedSessionId = UUID().uuidString
            let disconnected = self.mintPendingSession(
                manager,
                sessionId: disconnectedSessionId,
                resourceKind: .virtualMachine,
                resourceId: vmID.uuidString,
                auditContext: self.vmAuditContext(vmID: vmID, sessionId: disconnectedSessionId))
            _ = try manager.attachSession(
                sessionId: disconnected.sessionId,
                resourceKind: disconnected.resourceKind,
                resourceId: disconnected.resourceId,
                userId: disconnected.userId,
                websocket: nil)
            await manager.handleStarted(
                sessionId: disconnected.sessionId,
                fromAgentKey: agentKey("exec-agent"))

            await manager.handleClosed(
                sessionId: refused.sessionId,
                fromAgentKey: agentKey("exec-agent"),
                reason: "guest refused the process")
            await manager.handleClosed(
                sessionId: disconnected.sessionId,
                fromAgentKey: agentKey("exec-agent"),
                reason: "guest channel closed")

            let events = try await self.auditEvents(ofType: "vm.exec.ended", on: app)
            let outcomes: [String: String] = Dictionary(
                uniqueKeysWithValues: events.compactMap { event in
                    guard let correlationID = event.metadata?["correlationID"],
                        let outcome = event.metadata?["outcome"]
                    else { return nil }
                    return (correlationID, outcome)
                })
            #expect(outcomes[refusedSessionId] == "refused")
            #expect(outcomes[disconnectedSessionId] == "disconnected")
        }
    }

    @Test("Browser termination and agent disconnect append one typed end fact each")
    func controlPlaneTerminalPathsAreAudited() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let vmID = UUID()

            let terminatedSessionId = UUID().uuidString
            let terminated = self.mintPendingSession(
                manager,
                sessionId: terminatedSessionId,
                resourceKind: .virtualMachine,
                resourceId: vmID.uuidString,
                auditContext: self.vmAuditContext(vmID: vmID, sessionId: terminatedSessionId))
            _ = try manager.attachSession(
                sessionId: terminated.sessionId,
                resourceKind: terminated.resourceKind,
                resourceId: terminated.resourceId,
                userId: terminated.userId,
                websocket: nil)

            let disconnectedSessionId = UUID().uuidString
            let disconnected = self.mintPendingSession(
                manager,
                sessionId: disconnectedSessionId,
                resourceKind: .virtualMachine,
                resourceId: vmID.uuidString,
                auditContext: self.vmAuditContext(vmID: vmID, sessionId: disconnectedSessionId))
            _ = try manager.attachSession(
                sessionId: disconnected.sessionId,
                resourceKind: disconnected.resourceKind,
                resourceId: disconnected.resourceId,
                userId: disconnected.userId,
                websocket: nil)

            await manager.endSession(
                sessionId: terminated.sessionId,
                outcome: .terminated,
                reason: "browser disconnected")
            await manager.closeAllSessions(
                forAgent: agentKey("exec-agent"), reason: "agent disconnected")

            let events = try await self.auditEvents(ofType: "vm.exec.ended", on: app)
            let outcomes: [String: String] = Dictionary(
                uniqueKeysWithValues: events.compactMap { event in
                    guard let correlationID = event.metadata?["correlationID"],
                        let outcome = event.metadata?["outcome"]
                    else { return nil }
                    return (correlationID, outcome)
                })
            #expect(outcomes[terminatedSessionId] == "terminated")
            #expect(outcomes[disconnectedSessionId] == "disconnected")
        }
    }

    @Test("Racing terminal paths append exactly one end fact")
    func racingTerminalPathsAreAuditedOnce() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let vmID = UUID()
            let sessionId = UUID().uuidString
            let session = self.mintPendingSession(
                manager,
                sessionId: sessionId,
                resourceKind: .virtualMachine,
                resourceId: vmID.uuidString,
                auditContext: self.vmAuditContext(vmID: vmID, sessionId: sessionId))
            _ = try manager.attachSession(
                sessionId: session.sessionId,
                resourceKind: session.resourceKind,
                resourceId: session.resourceId,
                userId: session.userId,
                websocket: nil)

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await manager.handleExit(
                        sessionId: session.sessionId,
                        fromAgentKey: agentKey("exec-agent"),
                        exitCode: 0)
                }
                group.addTask {
                    await manager.endSession(
                        sessionId: session.sessionId,
                        outcome: .terminated,
                        reason: "browser disconnected")
                }
            }

            let events = try await self.auditEvents(ofType: "vm.exec.ended", on: app)
            #expect(events.count == 1)
            #expect(events.first?.metadata?["correlationID"] == sessionId)
            #expect(["exited", "terminated"].contains(events.first?.metadata?["outcome"] ?? ""))
        }
    }

    @Test("A typed control-plane timeout appends one timed-out end fact")
    func typedTimeoutIsAuditedOnce() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let vmID = UUID()
            let sessionId = UUID().uuidString
            let session = self.mintPendingSession(
                manager,
                sessionId: sessionId,
                resourceKind: .virtualMachine,
                resourceId: vmID.uuidString,
                auditContext: self.vmAuditContext(vmID: vmID, sessionId: sessionId))
            _ = try manager.attachSession(
                sessionId: session.sessionId,
                resourceKind: session.resourceKind,
                resourceId: session.resourceId,
                userId: session.userId,
                websocket: nil)

            await manager.endSession(
                sessionId: session.sessionId,
                outcome: .timedOut,
                reason: "typed exec timeout")
            await manager.endSession(
                sessionId: session.sessionId,
                outcome: .timedOut,
                reason: "duplicate timeout")

            let events = try await self.auditEvents(ofType: "vm.exec.ended", on: app)
            #expect(events.count == 1)
            #expect(events.first?.resourceType == "vms")
            #expect(events.first?.resourceID == vmID.uuidString)
            #expect(events.first?.metadata?["correlationID"] == sessionId)
            #expect(events.first?.metadata?["outcome"] == "timed_out")
            #expect(events.first?.metadata?["phase"] == "ended")
        }
    }

    @Test("Sandbox exec lifecycle does not emit VM audit events")
    func sandboxExecDoesNotEmitVMAuditEvents() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let session = self.mintPendingSession(manager)
            _ = try manager.attachSession(
                sessionId: session.sessionId,
                resourceKind: session.resourceKind,
                resourceId: session.resourceId,
                userId: session.userId,
                websocket: nil)

            await manager.handleStarted(
                sessionId: session.sessionId, fromAgentKey: agentKey("exec-agent"))
            await manager.handleExit(
                sessionId: session.sessionId,
                fromAgentKey: agentKey("exec-agent"),
                exitCode: 0)

            #expect(try await self.auditEvents(ofType: "vm.exec.started", on: app).isEmpty)
            #expect(try await self.auditEvents(ofType: "vm.exec.ended", on: app).isEmpty)
        }
    }

    @Test("Audit persistence failure cannot interrupt an interactive exec lifecycle")
    func execAuditPersistenceFailureIsFailOpen() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.guestExecSessionManager
            let vmID = UUID()
            let sessionId = UUID().uuidString
            let session = self.mintPendingSession(
                manager,
                sessionId: sessionId,
                resourceKind: .virtualMachine,
                resourceId: vmID.uuidString,
                auditContext: self.vmAuditContext(vmID: vmID, sessionId: sessionId))
            _ = try manager.attachSession(
                sessionId: session.sessionId,
                resourceKind: session.resourceKind,
                resourceId: session.resourceId,
                userId: session.userId,
                websocket: nil)

            // Remove the backing table before the lifecycle facts are queued.
            // `flush` below forces the fail-open backend through the actual
            // persistence error rather than merely proving that queueing is
            // asynchronous.
            try await app.db.schema(AuditEvent.schema).delete()
            await manager.handleStarted(
                sessionId: session.sessionId, fromAgentKey: agentKey("exec-agent"))
            #expect(manager.getSession(sessionId: session.sessionId)?.agentConfirmedStarted == true)

            await manager.handleExit(
                sessionId: session.sessionId,
                fromAgentKey: agentKey("exec-agent"),
                exitCode: 0)
            #expect(manager.getSession(sessionId: session.sessionId) == nil)

            await app.audit.flush()
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

            await manager.closeAllSessions(
                forAgent: agentKey("exec-agent"), reason: "agent disconnected")

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
