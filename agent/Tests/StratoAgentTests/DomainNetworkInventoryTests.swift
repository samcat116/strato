import Testing
@testable import StratoAgentCore
@testable import StratoAgentDomainXML
import StratoShared

@Suite("Libvirt network device inventory")
struct DomainNetworkInventoryTests {
    @Test("reads interface MACs case-insensitively and ignores host devices")
    func readsInterfaceMACs() throws {
        let xml = """
            <domain><devices>
              <interface type='ethernet'><mac address='52:54:00:AA:BB:01'/><target dev='tap0'/></interface>
              <hostdev><address value='not-a-mac'/></hostdev>
              <interface type='ethernet'><mac address='52:54:00:aa:bb:02'/></interface>
            </devices></domain>
            """
        #expect(
            try DomainNetworkInventory.macAddresses(inDomainXML: xml)
                == ["52:54:00:aa:bb:01", "52:54:00:aa:bb:02"])
    }

    @Test("network hot-plug XML reuses the domain builder and detach identifies by MAC")
    func deviceFragments() throws {
        let attachment = ResolvedNetworkAttachment(
            network: "storage",
            attachment: .tap(interface: "tap-vm-5"),
            macAddress: "52:54:00:aa:bb:05",
            mtu: 9000)
        #expect(
            try DomainDeviceXML.hotplugNetwork(attachment) == """
                <interface type='ethernet'>
                  <mac address='52:54:00:aa:bb:05'/>
                  <target dev='tap-vm-5' managed='no'/>
                  <model type='virtio'/>
                  <mtu size='9000'/>
                </interface>
                """ + "\n")
        #expect(
            DomainDeviceXML.detachNetwork(macAddress: "52:54:00:aa:bb:05") == """
                <interface type='ethernet'>
                  <mac address='52:54:00:aa:bb:05'/>
                </interface>
                """ + "\n")
    }

    @Test("malformed domain XML is not mistaken for an empty interface list")
    func rejectsMalformedXML() {
        #expect(throws: DomainInventoryError.self) {
            try DomainNetworkInventory.macAddresses(inDomainXML: "<domain><devices>")
        }
    }

    @Test(
        "network detach plans each live and persistent definition independently",
        arguments: [
            (live: true, config: true, expected: [DomainNetworkDetachScope.live, .config]),
            (live: true, config: false, expected: [.live]),
            (live: false, config: true, expected: [.config]),
            (live: false, config: false, expected: []),
        ])
    func detachPlanRecoversPartialState(
        live: Bool, config: Bool, expected: [DomainNetworkDetachScope]
    ) throws {
        let mac = "52:54:00:aa:bb:05"
        let withInterface = """
            <domain><devices>
              <interface type='ethernet'><mac address='\(mac)'/></interface>
            </devices></domain>
            """
        let withoutInterface = "<domain><devices/></domain>"
        let plan = try DomainNetworkDetachPlan(
            macAddress: mac,
            liveDomainXML: live ? withInterface : withoutInterface,
            inactiveDomainXML: config ? withInterface : withoutInterface)

        #expect(plan.scopes == expected)
    }

    @Test("an inactive domain plans only persistent detach")
    func inactiveDetachPlan() throws {
        let plan = try DomainNetworkDetachPlan(
            macAddress: "52:54:00:aa:bb:05",
            liveDomainXML: nil,
            inactiveDomainXML: """
                <domain><devices>
                  <interface type='ethernet'><mac address='52:54:00:aa:bb:05'/></interface>
                </devices></domain>
                """)

        #expect(plan.scopes == [.config])
    }
}
