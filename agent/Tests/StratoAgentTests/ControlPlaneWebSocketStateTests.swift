import Testing

@testable import StratoAgentCore

@Suite("Control-plane WebSocket state")
struct ControlPlaneWebSocketStateTests {
    @Test("A stale close cannot disconnect its successor")
    func staleCloseDoesNotDisconnectSuccessor() {
        var state = ControlPlaneWebSocketState()
        let first = state.beginConnection()
        let firstConnected = state.markConnected(first)
        #expect(firstConnected)

        let successor = state.beginConnection()
        let successorConnected = state.markConnected(successor)
        #expect(successorConnected)

        let staleClose = state.markClosed(first)
        #expect(staleClose == .stale)
        #expect(state.connectedGeneration == successor)
        let currentClose = state.markClosed(successor)
        #expect(currentClose == .unexpected)
        #expect(state.connectedGeneration == nil)
    }

    @Test("Intentional-close classification belongs only to that generation")
    func intentionalCloseIsGenerationScoped() {
        var state = ControlPlaneWebSocketState()
        let first = state.beginConnection()
        let firstConnected = state.markConnected(first)
        #expect(firstConnected)
        let intentional = state.beginIntentionalDisconnect()
        #expect(intentional == first)

        let successor = state.beginConnection()
        let successorConnected = state.markConnected(successor)
        #expect(successorConnected)

        let staleClose = state.markClosed(first)
        #expect(staleClose == .stale)
        #expect(state.connectedGeneration == successor)
        let currentClose = state.markClosed(successor)
        #expect(currentClose == .unexpected)
    }
}
