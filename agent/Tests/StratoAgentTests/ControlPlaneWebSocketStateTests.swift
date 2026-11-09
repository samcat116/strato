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
    @Test("A replacement socket cannot send workload before its own registration")
    func registrationCannotAuthorizeSuccessor() {
        var state = ControlPlaneWebSocketState()
        let first = state.beginConnection()
        let connectedFirst = state.markConnected(first)
        #expect(connectedFirst)
        #expect(!state.canSendWorkload)
        let registeredFirst = state.markRegistered(first)
        #expect(registeredFirst)
        #expect(state.canSendWorkload)

        let successor = state.beginConnection()
        #expect(!state.canSendWorkload)
        let connectedSuccessor = state.markConnected(successor)
        #expect(connectedSuccessor)
        let staleRegistration = state.markRegistered(first)
        #expect(!staleRegistration)
        #expect(!state.canSendWorkload)
        let registeredSuccessor = state.markRegistered(successor)
        #expect(registeredSuccessor)
        #expect(state.canSendWorkload)
        #expect(state.markClosed(first) == .stale)
        #expect(state.canSendWorkload)
        #expect(state.beginIntentionalDisconnect() == successor)
        #expect(!state.canSendWorkload)
    }

}
