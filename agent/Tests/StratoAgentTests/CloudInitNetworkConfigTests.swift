import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Cloud-init network-config generation")
struct CloudInitNetworkConfigTests {

    @Test("static tap NIC renders a v2 ethernet entry matched by MAC")
    func staticTapNIC() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0123456789ab"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                gateway: "192.168.1.1"
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml != nil)
        guard let yaml else { return }

        #expect(yaml.contains("version: 2"))
        #expect(yaml.contains("macaddress: \"52:54:00:aa:bb:cc\""))
        #expect(yaml.contains("- 192.168.1.5/24"))
        #expect(yaml.contains("gateway4: 192.168.1.1"))
    }

    @Test("gateway and MTU are optional")
    func optionalFields() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tapX"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "10.0.0.9",
                netmask: "255.255.0.0",
                mtu: 9000
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml != nil)
        #expect(yaml?.contains("gateway4") == false)
        #expect(yaml?.contains("mtu: 9000") == true)
        #expect(yaml?.contains("- 10.0.0.9/16") == true)
    }

    @Test("user-mode NICs are skipped (SLIRP provides DHCP)")
    func userModeSkipped() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .userMode,
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0"
            )
        ]
        #expect(CloudInitProvisioner.networkConfigYAML(for: attachments) == nil)
    }

    @Test("NICs without a static allocation produce no network-config")
    func noAllocationNoConfig() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tapX"),
                macAddress: "52:54:00:aa:bb:cc"
            )
        ]
        #expect(CloudInitProvisioner.networkConfigYAML(for: attachments) == nil)
        #expect(CloudInitProvisioner.networkConfigYAML(for: []) == nil)
    }

    @Test("DHCP-managed NIC renders dhcp4:true and no static address")
    func dhcpManagedNIC() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                gateway: "192.168.1.1",
                dhcpEnabled: true,
                dnsServers: ["1.1.1.1"]
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml != nil)
        #expect(yaml?.contains("macaddress: \"52:54:00:aa:bb:cc\"") == true)
        #expect(yaml?.contains("dhcp4: true") == true)
        // OVN's responder delivers the address/DNS, so no static block is written.
        #expect(yaml?.contains("addresses:") == false)
        #expect(yaml?.contains("nameservers:") == false)
    }

    @Test("static NIC with DNS renders nameservers")
    func staticNICWithDNS() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                gateway: "192.168.1.1",
                dhcpEnabled: false,
                dnsServers: ["1.1.1.1", "8.8.8.8"]
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.contains("- 192.168.1.5/24") == true)
        #expect(yaml?.contains("nameservers:") == true)
        #expect(yaml?.contains("addresses: [1.1.1.1, 8.8.8.8]") == true)
    }

    @Test("multiple NICs render as separate entries with stable names")
    func multipleNICs() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tapA"),
                macAddress: "52:54:00:00:00:01",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                gateway: "192.168.1.1"
            ),
            ResolvedNetworkAttachment(
                network: "backend",
                attachment: .tap(interface: "tapB"),
                macAddress: "52:54:00:00:00:02",
                ipAddress: "10.10.0.5",
                netmask: "255.255.255.0"
            ),
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.contains("nic0:") == true)
        #expect(yaml?.contains("nic1:") == true)
        #expect(yaml?.contains("- 10.10.0.5/24") == true)
    }
}
