import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Tests for the sandbox exec surface (issue #423): `POST /api/sandboxes/:id/exec`
/// validation and gating, the `SandboxExecSessionManager` pending/attach
/// lifecycle, agent-ownership anti-spoofing, and the sandbox logs endpoint's
/// Loki gating. The browser-attach WebSocket relay itself needs a live agent
/// socket, so HTTP tests stop at the "agent not connected to this replica"
/// boundary.
@Suite("Sandbox Exec Tests", .serialized)
final class SandboxExecTests {

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

    /// Registers an in-memory Firecracker-capable agent (current wire
    /// protocol) and optionally maps the sandbox to it. Returns the agent's
    /// UUID string.
    private func registerAgent(
        app: Application,
        sandbox: Sandbox? = nil,
        named agentName: String = "exec-agent"
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

    @Test("POST exec is rejected (409) when the agent's wire protocol predates exec")
    func execRejectsOldAgentProtocol() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)
            let agent = try #require(await Agent.find(UUID(uuidString: agentId), on: app.db))
            agent.wireProtocolVersion = WireProtocol.sandboxExecMinimumVersion - 1
            try await agent.save(on: app.db)

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

    // MARK: - Session manager lifecycle

    private func mintPendingSession(
        _ manager: SandboxExecSessionManager,
        sandboxId: String = UUID().uuidString,
        userId: String = UUID().uuidString,
        now: Date = Date()
    ) -> SandboxExecSessionManager.PendingExecSession {
        manager.createPendingSession(
            sandboxId: sandboxId,
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
            let manager = app.sandboxExecSessionManager
            let now = Date()
            let session = self.mintPendingSession(manager, now: now)

            #expect(session.command == ["/bin/sh", "-c", "echo hi"])
            #expect(session.tty == true)
            #expect(session.rows == 24)
            #expect(session.cols == 80)
            let expectedExpiry = now.addingTimeInterval(SandboxExecSessionManager.pendingSessionTTL)
            #expect(session.expiresAt == expectedExpiry)
            let exists = manager.hasPendingSession(sessionId: session.sessionId, now: now)
            #expect(exists == true)
        }
    }

    @Test("Pending sessions expire after the TTL and are swept on access")
    func pendingSessionExpires() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.sandboxExecSessionManager
            let now = Date()
            let session = self.mintPendingSession(manager, now: now)
            let later = now.addingTimeInterval(SandboxExecSessionManager.pendingSessionTTL + 1)

            // Attaching after the TTL reports expiry...
            do {
                _ = try manager.attachSession(
                    sessionId: session.sessionId,
                    sandboxId: session.sandboxId,
                    userId: session.userId,
                    websocket: nil,
                    now: later
                )
                Issue.record("Expected sessionExpired to be thrown")
            } catch let error as SandboxExecSessionError {
                #expect(error == .sessionExpired(session.sessionId))
            }

            // ...and the entry is gone afterwards.
            let stillThere = manager.hasPendingSession(sessionId: session.sessionId, now: later)
            #expect(stillThere == false)
        }
    }

    @Test("Attach validates the sandbox and user the session was minted for")
    func attachValidatesSandboxAndUser() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.sandboxExecSessionManager
            let session = self.mintPendingSession(manager)

            do {
                _ = try manager.attachSession(
                    sessionId: session.sessionId,
                    sandboxId: UUID().uuidString,
                    userId: session.userId,
                    websocket: nil
                )
                Issue.record("Expected sessionMismatch for a foreign sandbox")
            } catch let error as SandboxExecSessionError {
                #expect(error == .sessionMismatch(session.sessionId))
            }

            do {
                _ = try manager.attachSession(
                    sessionId: session.sessionId,
                    sandboxId: session.sandboxId,
                    userId: UUID().uuidString,
                    websocket: nil
                )
                Issue.record("Expected sessionMismatch for a foreign user")
            } catch let error as SandboxExecSessionError {
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
            let manager = app.sandboxExecSessionManager
            let bogus = UUID().uuidString

            do {
                _ = try manager.attachSession(
                    sessionId: bogus,
                    sandboxId: UUID().uuidString,
                    userId: UUID().uuidString,
                    websocket: nil
                )
                Issue.record("Expected sessionNotFound")
            } catch let error as SandboxExecSessionError {
                #expect(error == .sessionNotFound(bogus))
            }
        }
    }

    @Test("Attach consumes the pending session; a second attach is rejected")
    func duplicateAttachRejected() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.sandboxExecSessionManager
            let session = self.mintPendingSession(manager)

            let attached = try manager.attachSession(
                sessionId: session.sessionId,
                sandboxId: session.sandboxId,
                userId: session.userId,
                websocket: nil
            )
            #expect(attached.command == session.command)
            let pendingAfterAttach = manager.hasPendingSession(sessionId: session.sessionId)
            #expect(pendingAfterAttach == false)
            let info = manager.getSession(sessionId: session.sessionId)
            #expect(info?.sandboxId == session.sandboxId)
            #expect(info?.agentKey == agentKey("exec-agent"))

            do {
                _ = try manager.attachSession(
                    sessionId: session.sessionId,
                    sandboxId: session.sandboxId,
                    userId: session.userId,
                    websocket: nil
                )
                Issue.record("Expected alreadyAttached")
            } catch let error as SandboxExecSessionError {
                #expect(error == .alreadyAttached(session.sessionId))
            }

            // The per-sandbox index tracks the attached session and empties
            // on removal.
            let forSandbox = manager.getSessionsForSandbox(sandboxId: session.sandboxId)
            #expect(forSandbox.count == 1)
            manager.removeSession(sessionId: session.sessionId)
            let afterRemoval = manager.getSessionsForSandbox(sandboxId: session.sandboxId)
            #expect(afterRemoval.isEmpty)
            #expect(manager.getSession(sessionId: session.sessionId) == nil)
        }
    }

    @Test("Terminal agent events only tear down sessions owned by the reporting agent")
    func terminalEventsRequireOwningAgent() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let manager = app.sandboxExecSessionManager
            let session = self.mintPendingSession(manager)
            _ = try manager.attachSession(
                sessionId: session.sessionId,
                sandboxId: session.sandboxId,
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
            let manager = app.sandboxExecSessionManager

            // One attached and one still-pending session for the
            // disconnecting agent...
            let attached = self.mintPendingSession(manager)
            _ = try manager.attachSession(
                sessionId: attached.sessionId,
                sandboxId: attached.sandboxId,
                userId: attached.userId,
                websocket: nil
            )
            let pending = self.mintPendingSession(manager)

            // ...and an attached session on a different agent that must
            // survive the teardown.
            let otherSandboxId = UUID().uuidString
            let otherUserId = UUID().uuidString
            let other = manager.createPendingSession(
                sandboxId: otherSandboxId,
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
                sandboxId: otherSandboxId,
                userId: otherUserId,
                websocket: nil
            )

            manager.closeAllSessions(forAgent: agentKey("exec-agent"), reason: "agent disconnected")

            #expect(manager.getSession(sessionId: attached.sessionId) == nil)
            let attachedIndex = manager.getSessionsForSandbox(sandboxId: attached.sandboxId)
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
            let manager = app.sandboxExecSessionManager
            let bogus = UUID().uuidString

            do {
                try await manager.routeInput(sessionId: bogus, data: Data([0x6C, 0x73]))
                Issue.record("Expected sessionNotFound")
            } catch let error as SandboxExecSessionError {
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
