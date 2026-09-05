import Testing

@testable import StratoAgentRuntime

@Suite("Network service topology")
struct NetworkServiceLinuxTopologyTests {
    @Test("Router-port parent drift includes missing, wrong, and multiple parents")
    func routerPortParentDrift() {
        let portUUID = "port-uuid"

        #expect(
            !NetworkServiceLinux.routerPortNeedsReparent(
                portUUID: portUUID,
                desiredRouter: "desired",
                routerPortUUIDsByRouter: ["desired": [portUUID]]))
        #expect(
            NetworkServiceLinux.routerPortNeedsReparent(
                portUUID: portUUID,
                desiredRouter: "desired",
                routerPortUUIDsByRouter: [:]))
        #expect(
            NetworkServiceLinux.routerPortNeedsReparent(
                portUUID: portUUID,
                desiredRouter: "desired",
                routerPortUUIDsByRouter: ["old": [portUUID]]))
        #expect(
            NetworkServiceLinux.routerPortNeedsReparent(
                portUUID: portUUID,
                desiredRouter: "desired",
                routerPortUUIDsByRouter: [
                    "desired": [portUUID],
                    "old": [portUUID],
                ]))
    }
}
