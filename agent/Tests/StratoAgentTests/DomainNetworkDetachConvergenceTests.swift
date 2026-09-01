import StratoAgentCore
import Testing

@testable import StratoAgent

private actor RebootingDomainDefinitions {
    private let macAddress = "52:54:00:aa:bb:05"
    private var liveContainsInterface = true
    private var configContainsInterface = true
    private var rebooted = false
    private var detachedScopes: [DomainNetworkDetachScope] = []

    func observe() throws -> DomainNetworkDetachPlan {
        try DomainNetworkDetachPlan(
            macAddress: macAddress,
            liveDomainXML: domainXML(containsInterface: liveContainsInterface),
            inactiveDomainXML: domainXML(containsInterface: configContainsInterface))
    }

    func detach(_ scope: DomainNetworkDetachScope) {
        detachedScopes.append(scope)
        switch scope {
        case .live:
            liveContainsInterface = false
        case .config:
            if !rebooted {
                liveContainsInterface = configContainsInterface
                rebooted = true
            }
            configContainsInterface = false
        }
    }

    func scopesApplied() -> [DomainNetworkDetachScope] {
        detachedScopes
    }

    private func domainXML(containsInterface: Bool) -> String {
        guard containsInterface else { return "<domain><devices/></domain>" }
        return """
            <domain><devices>
              <interface type='ethernet'><mac address='\(macAddress)'/></interface>
            </devices></domain>
            """
    }
}

@Suite("Libvirt network detach convergence")
struct DomainNetworkDetachConvergenceTests {
    @Test("replans when a reboot restores the live NIC during persistent detach")
    func rechecksLiveDefinitionAfterConfigDetach() async throws {
        let definitions = RebootingDomainDefinitions()

        let didDetach = try await DomainNetworkDetachConvergence.run {
            try await definitions.observe()
        } detach: { scope in
            await definitions.detach(scope)
        }

        #expect(didDetach)
        #expect(try await definitions.observe().scopes.isEmpty)
        #expect(await definitions.scopesApplied() == [.live, .config, .live])
    }
}
