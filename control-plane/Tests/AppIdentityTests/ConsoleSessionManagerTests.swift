import Foundation
import Testing
import Vapor

import AppTestSupport
@testable import App

@Suite("ConsoleSessionManager Tests", .serialized)
final class ConsoleSessionManagerTests: BaseTestCase {

    @Test("Session lifecycle: create, look up, remove, and per-VM index")
    func sessionLifecycle() async throws {
        try await withApp { app in
            let manager = app.consoleSessionManager
            let sessionId = UUID().uuidString
            let vmId = UUID().uuidString

            manager.createSession(
                sessionId: sessionId,
                vmId: vmId,
                agentKey: agentKey("console-agent"),
                userId: nil,
                websocket: nil
            )

            #expect(manager.hasSession(sessionId: sessionId))
            let info = manager.getSession(sessionId: sessionId)
            #expect(info?.vmId == vmId)
            #expect(info?.agentKey == agentKey("console-agent"))

            let forVM = manager.getSessionsForVM(vmId: vmId)
            #expect(forVM.count == 1)

            manager.removeSession(sessionId: sessionId)
            #expect(manager.getSession(sessionId: sessionId) == nil)
            let afterRemoval = manager.getSessionsForVM(vmId: vmId)
            #expect(afterRemoval.isEmpty)
        }
    }

    @Test("Agent disconnect tears down that agent's console sessions")
    func agentDisconnectClosesSessions() async throws {
        try await withApp { app in
            let manager = app.consoleSessionManager

            // Two sessions on the disconnecting agent — one of them a second
            // viewer of the same VM console...
            let vmId = UUID().uuidString
            let firstSession = UUID().uuidString
            let secondSession = UUID().uuidString
            manager.createSession(
                sessionId: firstSession,
                vmId: vmId,
                agentKey: agentKey("console-agent"),
                userId: nil,
                websocket: nil
            )
            manager.createSession(
                sessionId: secondSession,
                vmId: vmId,
                agentKey: agentKey("console-agent"),
                userId: nil,
                websocket: nil
            )

            // ...and a session on a different agent that must survive the
            // teardown.
            let otherVmId = UUID().uuidString
            let otherSession = UUID().uuidString
            manager.createSession(
                sessionId: otherSession,
                vmId: otherVmId,
                agentKey: agentKey("other-agent"),
                userId: nil,
                websocket: nil
            )

            manager.closeAllSessions(forAgent: agentKey("console-agent"), reason: "agent disconnected")

            #expect(manager.getSession(sessionId: firstSession) == nil)
            #expect(manager.getSession(sessionId: secondSession) == nil)
            let vmIndex = manager.getSessionsForVM(vmId: vmId)
            #expect(vmIndex.isEmpty)

            // The other agent's session is untouched.
            #expect(manager.getSession(sessionId: otherSession) != nil)
            let otherIndex = manager.getSessionsForVM(vmId: otherVmId)
            #expect(otherIndex.count == 1)
        }
    }

    // MARK: - Graphics console sessions (issue #566)

    @Test("A minted graphics session attaches once and records its stream")
    func vncSessionMintAndAttach() async throws {
        try await withApp { app in
            let manager = app.consoleSessionManager
            let vmId = UUID().uuidString
            let userId = UUID().uuidString

            let pending = manager.createPendingVNCSession(
                vmId: vmId, agentKey: agentKey("console-agent"), userId: userId)

            // Minting alone must not create an attached session — nothing is
            // routable until the browser actually connects.
            #expect(!manager.hasSession(sessionId: pending.sessionId))

            try manager.attachVNCSession(
                sessionId: pending.sessionId, vmId: vmId, userId: userId, websocket: nil)

            let info = manager.getSession(sessionId: pending.sessionId)
            #expect(info?.vmId == vmId)
            #expect(info?.stream == .vnc)
            #expect(manager.getSessionsForVM(vmId: vmId).count == 1)

            // Single-use: a replayed attach cannot open a second relay against
            // the same session id.
            #expect(throws: ConsoleSessionError.self) {
                try manager.attachVNCSession(
                    sessionId: pending.sessionId, vmId: vmId, userId: userId, websocket: nil)
            }
        }
    }

    /// The session id is the only credential on the attach URL, so a leaked one
    /// must not let a different user — or a different VM's tab — attach.
    @Test("A graphics session rejects the wrong VM, the wrong user, and expiry")
    func vncSessionRejectsMismatchAndExpiry() async throws {
        try await withApp { app in
            let manager = app.consoleSessionManager
            let vmId = UUID().uuidString
            let userId = UUID().uuidString

            let pending = manager.createPendingVNCSession(
                vmId: vmId, agentKey: agentKey("console-agent"), userId: userId)

            #expect(throws: ConsoleSessionError.self) {
                try manager.attachVNCSession(
                    sessionId: pending.sessionId, vmId: UUID().uuidString, userId: userId, websocket: nil)
            }
            #expect(throws: ConsoleSessionError.self) {
                try manager.attachVNCSession(
                    sessionId: pending.sessionId, vmId: vmId, userId: UUID().uuidString, websocket: nil)
            }

            // Still attachable, since neither rejection consumed it.
            try manager.attachVNCSession(
                sessionId: pending.sessionId, vmId: vmId, userId: userId, websocket: nil)
            manager.removeSession(sessionId: pending.sessionId)

            // Past its TTL an abandoned mint cannot be replayed.
            let stale = manager.createPendingVNCSession(
                vmId: vmId, agentKey: agentKey("console-agent"), userId: userId)
            #expect(throws: ConsoleSessionError.self) {
                try manager.attachVNCSession(
                    sessionId: stale.sessionId, vmId: vmId, userId: userId, websocket: nil,
                    now: stale.expiresAt.addingTimeInterval(1))
            }
        }
    }

    /// The reason has to survive as JSON the frontend can parse. It carries
    /// agent-written text, and the close frame cannot hold it — WebSocketKit's
    /// `close(code:)` writes a two-byte status code and nothing else — so a
    /// hand-escaped string that broke on a newline would put the failure right
    /// back where it started: a blank "Disconnected".
    @Test("An error control frame stays valid JSON for reasons with awkward characters")
    func errorControlFrameSurvivesAwkwardReasons() async throws {
        try await withApp { _ in
            let reason = "VM \"x\" has no display:\n\tuse a \\qemu\\ image"
            let frame = ConsoleSessionManager.errorControlFrame(reason)

            struct Decoded: Decodable {
                let type: String
                let message: String
            }
            let decoded = try JSONDecoder().decode(Decoded.self, from: Data(frame.utf8))
            #expect(decoded.type == "error")
            #expect(decoded.message == reason)
        }
    }

    /// A mint whose agent socket dropped can only ever fail on attach — and it
    /// would fail after the upgrade, where explaining why is hardest.
    @Test("Agent disconnect drops that agent's unattached graphics sessions")
    func agentDisconnectDropsPendingVNCSessions() async throws {
        try await withApp { app in
            let manager = app.consoleSessionManager
            let vmId = UUID().uuidString
            let userId = UUID().uuidString

            let doomed = manager.createPendingVNCSession(
                vmId: vmId, agentKey: agentKey("console-agent"), userId: userId)
            let survivor = manager.createPendingVNCSession(
                vmId: UUID().uuidString, agentKey: agentKey("other-agent"), userId: userId)

            manager.closeAllSessions(forAgent: agentKey("console-agent"), reason: "agent disconnected")

            #expect(throws: ConsoleSessionError.self) {
                try manager.attachVNCSession(
                    sessionId: doomed.sessionId, vmId: vmId, userId: userId, websocket: nil)
            }
            // The other agent's mint is untouched.
            try manager.attachVNCSession(
                sessionId: survivor.sessionId, vmId: survivor.vmId, userId: userId, websocket: nil)
        }
    }
}
