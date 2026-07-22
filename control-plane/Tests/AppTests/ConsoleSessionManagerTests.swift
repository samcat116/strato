import Fluent
import Foundation
import Testing
import Vapor

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
}
