import Testing

@testable import StratoAgentCore

@Suite("Control-plane reconnect state")
struct ControlPlaneReconnectStateTests {
    @Test("A second socket loss invalidates recovery already in progress")
    func secondLossInvalidatesCurrentAttempt() {
        var state = ControlPlaneReconnectState()

        #expect(state.recordConnectionLoss() == .startLoop)
        let firstAttempt = state.beginAttempt()

        #expect(state.recordConnectionLoss() == .loopAlreadyActive)
        #expect(!state.canFinish(firstAttempt))

        let retry = state.beginAttempt()
        #expect(state.canFinish(retry))

        state.finishLoop()
        #expect(state.recordConnectionLoss() == .startLoop)
    }

    @Test("A socket loss during startup remains pending until startup hands it off")
    func startupLossIsRemembered() {
        var state = ControlPlaneReconnectState()

        state.recordStartupConnectionLoss()
        #expect(state.connectionWasLostDuringStartup)
        let consumedLoss = state.consumeStartupConnectionLoss()
        #expect(consumedLoss)
        #expect(!state.connectionWasLostDuringStartup)
        let consumedAgain = state.consumeStartupConnectionLoss()
        #expect(!consumedAgain)
    }

    @Test("A queued frame cannot cross a connection generation")
    func interactiveFenceRejectsQueuedFrameFromLostSocket() {
        var websocketState = ControlPlaneWebSocketState()
        let first = websocketState.beginConnection()
        let connectedFirst = websocketState.markConnected(first)
        #expect(connectedFirst)

        var fence = ControlPlaneInteractiveSessionFence()
        fence.activate(generation: first)
        #expect(fence.accepts(generation: first))

        fence.quiesce()
        #expect(!fence.accepts(generation: first))

        let successor = websocketState.beginConnection()
        let connectedSuccessor = websocketState.markConnected(successor)
        #expect(connectedSuccessor)
        fence.activate(generation: successor)
        #expect(fence.accepts(generation: successor))
        #expect(!fence.accepts(generation: first))
    }
}
