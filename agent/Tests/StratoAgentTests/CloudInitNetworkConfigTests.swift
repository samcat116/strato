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
        // No domain on the network: no search list at all.
        #expect(yaml?.contains("search:") == false)
    }

    @Test("static NIC with a domain renders the search list alongside nameservers")
    func staticNICWithSearchDomain() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                gateway: "192.168.1.1",
                dhcpEnabled: false,
                dnsServers: ["1.1.1.1"],
                domainName: "corp.example.com"
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(
            yaml == """
                version: 2
                ethernets:
                  nic0:
                    match:
                      macaddress: "52:54:00:aa:bb:cc"
                    set-name: nic0
                    addresses:
                      - 192.168.1.5/24
                    gateway4: 192.168.1.1
                    nameservers:
                      search: ["corp.example.com"]
                      addresses: [1.1.1.1]
                """)
    }

    @Test("a domain with no resolvers still renders a nameservers search list")
    func searchDomainWithoutResolvers() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                domainName: "corp.example.com"
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.contains("nameservers:") == true)
        #expect(yaml?.contains(#"search: ["corp.example.com"]"#) == true)
        #expect(yaml?.contains("addresses: [") == false)
    }

    @Test("a blank domain renders no search list")
    func blankSearchDomainOmitted() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                domainName: "   "
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml != nil)
        #expect(yaml?.contains("nameservers") == false)
    }

    @Test("a domain that is only a newline renders no search list")
    func newlineOnlySearchDomainOmitted() {
        // The trim used to be `.whitespaces`, which leaves a newline standing:
        // the domain read as non-empty and rendered an empty `search` entry.
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                domainName: " \n "
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml != nil)
        #expect(yaml?.contains("nameservers") == false)
    }

    @Test("a structured domain from a row predating validation stays one scalar")
    func searchDomainCannotRestructureTheDocument() {
        // The control plane rejects this on write (issue #876), but rows written
        // before that validation keep whatever they hold, so the renderer has to
        // be safe on its own: the smuggled netplan keys must land inside the
        // search scalar rather than beside it as a sibling `routes:` block.
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                gateway: "192.168.1.1",
                domainName: "corp.example.com\n    routes:\n      - to: 0.0.0.0/0\n        via: 10.0.0.99"
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(
            yaml == """
                version: 2
                ethernets:
                  nic0:
                    match:
                      macaddress: "52:54:00:aa:bb:cc"
                    set-name: nic0
                    addresses:
                      - 192.168.1.5/24
                    gateway4: 192.168.1.1
                    nameservers:
                      search: ["corp.example.com\\n    routes:\\n      - to: 0.0.0.0/0\\n        via: 10.0.0.99"]
                """)
        #expect(yaml?.contains("\n    routes:") == false)
    }

    @Test("resolvers that are not addresses are dropped from the flow sequence")
    func nonAddressResolversDropped() {
        // Same flow sequence the search domain is quoted for, so the entries
        // are filtered the way `OVNDHCPOptionsBuilder` filters them rather than
        // being trusted to be addresses.
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                dnsServers: ["1.1.1.1", "not-an-address]", "fd00::53"]
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.contains("addresses: [1.1.1.1, fd00::53]") == true)
        #expect(yaml?.contains("not-an-address") == false)
    }

    @Test("quoting escapes what would otherwise end the search scalar")
    func searchDomainQuotingEscapesDelimiters() {
        #expect(CloudInitProvisioner.yamlQuoted("corp.example.com") == #""corp.example.com""#)
        // `]`, `,`, and `#` are data inside quotes — unquoted, each one made the
        // flow sequence unparseable and cost the guest its whole network-config.
        #expect(CloudInitProvisioner.yamlQuoted("a],b # c") == #""a],b # c""#)
        // The quote and backslash would end or reinterpret the scalar itself.
        #expect(CloudInitProvisioner.yamlQuoted(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(CloudInitProvisioner.yamlQuoted("a\nb\tc\rd") == #""a\nb\tc\rd""#)
    }

    @Test("DHCP NIC writes no search list (OVN's responder delivers the domain)")
    func dhcpNICOmitsSearchDomain() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                dhcpEnabled: true,
                dnsServers: ["1.1.1.1"],
                domainName: "corp.example.com"
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.contains("dhcp4: true") == true)
        #expect(yaml?.contains("search:") == false)
        #expect(yaml?.contains("nameservers") == false)
    }

    @Test("v4-only NICs render byte-identical YAML to pre-IPv6 agents")
    func v4OnlyOutputUnchanged() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                gateway: "192.168.1.1"
            )
        ]
        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(
            yaml == """
                version: 2
                ethernets:
                  nic0:
                    match:
                      macaddress: "52:54:00:aa:bb:cc"
                    set-name: nic0
                    addresses:
                      - 192.168.1.5/24
                    gateway4: 192.168.1.1
                """)
    }

    @Test("dual-stack static NIC renders both addresses, gateway6, RA acceptance, and EUI-64")
    func dualStackStaticNIC() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                gateway: "192.168.1.1",
                ip6Address: "fd12:3456:789a::100",
                prefixLength6: 64,
                gateway6: "fd12:3456:789a::1",
                dnsServers: ["1.1.1.1", "fd00::53"]
            )
        ]
        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.contains("- 192.168.1.5/24") == true)
        #expect(yaml?.contains("- fd12:3456:789a::100/64") == true)
        #expect(yaml?.contains("gateway4: 192.168.1.1") == true)
        #expect(yaml?.contains("gateway6: fd12:3456:789a::1") == true)
        #expect(yaml?.contains("accept-ra: true") == true)
        // EUI-64 link-locals are what OVN port_security allows; stable-privacy
        // link-locals would be silently dropped.
        #expect(yaml?.contains("ipv6-address-generation: eui64") == true)
        // The nameserver list stays mixed-family.
        #expect(yaml?.contains("addresses: [1.1.1.1, fd00::53]") == true)
    }

    @Test("dual-stack DHCP NIC renders dhcp4 + dhcp6 with RA acceptance and EUI-64")
    func dualStackDHCPNIC() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                gateway: "192.168.1.1",
                ip6Address: "fd12:3456:789a::100",
                prefixLength6: 64,
                gateway6: "fd12:3456:789a::1",
                dhcpEnabled: true
            )
        ]
        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.contains("dhcp4: true") == true)
        #expect(yaml?.contains("dhcp6: true") == true)
        #expect(yaml?.contains("accept-ra: true") == true)
        #expect(yaml?.contains("ipv6-address-generation: eui64") == true)
        #expect(yaml?.contains("addresses:") == false)
    }

    @Test("v4-only DHCP NIC renders no v6 keys")
    func v4OnlyDHCPNoV6Keys() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                dhcpEnabled: true
            )
        ]
        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.contains("dhcp6") == false)
        #expect(yaml?.contains("accept-ra") == false)
        #expect(yaml?.contains("ipv6-address-generation") == false)
    }

    @Test("a static NIC on a metadata network carries an on-link route to the IMDS")
    func staticNICCarriesMetadataRoute() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                gateway: "192.168.1.1",
                metadataEnabled: true
            )
        ]

        #expect(
            CloudInitProvisioner.networkConfigYAML(for: attachments) == """
                version: 2
                ethernets:
                  nic0:
                    match:
                      macaddress: "52:54:00:aa:bb:cc"
                    set-name: nic0
                    addresses:
                      - 192.168.1.5/24
                    gateway4: 192.168.1.1
                    routes:
                      - to: 169.254.169.254/32
                        via: 0.0.0.0
                """)
    }

    @Test("a dual-stack static NIC carries both families' metadata routes")
    func dualStackStaticNICCarriesBothMetadataRoutes() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                gateway: "192.168.1.1",
                ip6Address: "fd12:3456:789a::100",
                prefixLength6: 64,
                gateway6: "fd12:3456:789a::1",
                metadataEnabled: true
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.contains("- to: 169.254.169.254/32") == true)
        #expect(yaml?.contains("- to: fd00:ec2::254/128") == true)
        // Quoted, or the document is a YAML scanner error rather than a config.
        #expect(yaml?.contains(#"via: "::""#) == true)
    }

    @Test("a DHCP NIC takes its v4 metadata route from option 121, not the seed")
    func dhcpNICOmitsIPv4MetadataRoute() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                gateway: "192.168.1.1",
                dhcpEnabled: true,
                metadataEnabled: true
            )
        ]

        // v4-only and DHCP-managed: OVN's responder already delivers the route,
        // so this section is byte-identical to a network without the service.
        #expect(
            CloudInitProvisioner.networkConfigYAML(for: attachments) == """
                version: 2
                ethernets:
                  nic0:
                    match:
                      macaddress: "52:54:00:aa:bb:cc"
                    set-name: nic0
                    dhcp4: true
                """)
    }

    @Test("a dual-stack DHCP NIC still needs the seed for its v6 metadata route")
    func dualStackDHCPNICCarriesIPv6MetadataRouteOnly() {
        // DHCPv6 has no option 121 and an RA cannot carry an on-link route to
        // the localport, so this document is the only path the v6 route has.
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                gateway: "192.168.1.1",
                ip6Address: "fd12:3456:789a::100",
                prefixLength6: 64,
                dhcpEnabled: true,
                metadataEnabled: true
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.contains("- to: fd00:ec2::254/128") == true)
        #expect(yaml?.contains("169.254.169.254") == false)
    }

    @Test("a v4-only NIC gets no route to the v6 metadata address")
    func v4OnlyNICOmitsIPv6MetadataRoute() {
        // With no global IPv6 address the guest has no valid source address for
        // a ULA destination, so the route would only ever fail.
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                metadataEnabled: true
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.contains("- to: 169.254.169.254/32") == true)
        #expect(yaml?.contains("fd00:ec2") == false)
    }

    @Test("a NIC whose network has the metadata service off carries no route")
    func metadataDisabledNICCarriesNoRoute() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tap0"),
                macAddress: "52:54:00:aa:bb:cc",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                ip6Address: "fd12:3456:789a::100",
                prefixLength6: 64
            )
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.contains("routes:") == false)
    }

    @Test("exactly one NIC carries the metadata routes — the first eligible one")
    func onlyOneNICCarriesTheMetadataRoutes() {
        // Two interfaces claiming the same destination is a duplicate route the
        // guest resolves arbitrarily. NIC 0 is on a network with the service
        // off, so the claim falls to NIC 1 rather than being dropped.
        let attachments = [
            ResolvedNetworkAttachment(
                network: "unmanaged",
                attachment: .tap(interface: "tapA"),
                macAddress: "52:54:00:00:00:01",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0"
            ),
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tapB"),
                macAddress: "52:54:00:00:00:02",
                ipAddress: "10.10.0.5",
                netmask: "255.255.255.0",
                metadataEnabled: true
            ),
            ResolvedNetworkAttachment(
                network: "second",
                attachment: .tap(interface: "tapC"),
                macAddress: "52:54:00:00:00:03",
                ipAddress: "10.20.0.5",
                netmask: "255.255.255.0",
                metadataEnabled: true
            ),
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.components(separatedBy: "169.254.169.254/32").count == 2)
        // ...and it is nic1's section that carries it.
        // (v6 asserted separately in `dualStackNICsRenderOneIPv6MetadataRoute` —
        // it has no option-121 backstop to hide a duplicate.)
        #expect(
            yaml?.contains(
                """
                  nic1:
                    match:
                      macaddress: "52:54:00:00:00:02"
                    set-name: nic1
                    addresses:
                      - 10.10.0.5/24
                    routes:
                      - to: 169.254.169.254/32
                        via: 0.0.0.0
                """) == true)
    }

    @Test("a v4-only NIC does not consume the v6 metadata claim")
    func v4OnlyNICDoesNotConsumeTheIPv6MetadataClaim() {
        // Same class of bug as `skippedNICDoesNotConsumeTheMetadataClaim`, on
        // the family axis: nic0 settles v4 (its DHCP lease carries option 121)
        // while rendering nothing, and one claim covering both families would
        // let it swallow nic1's v6 route — the only v6 delivery path there is.
        let attachments = [
            ResolvedNetworkAttachment(
                network: "v4-only",
                attachment: .tap(interface: "tapA"),
                macAddress: "52:54:00:00:00:01",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                dhcpEnabled: true,
                metadataEnabled: true
            ),
            ResolvedNetworkAttachment(
                network: "dual-stack",
                attachment: .tap(interface: "tapB"),
                macAddress: "52:54:00:00:00:02",
                ipAddress: "10.10.0.5",
                netmask: "255.255.255.0",
                ip6Address: "fd12:3456:789a::100",
                prefixLength6: 64,
                metadataEnabled: true
            ),
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.contains("- to: fd00:ec2::254/128") == true)
        // ...while nic0's DHCP lease still settles v4, so the static nic1 does
        // not write a second route to the same v4 destination.
        #expect(yaml?.contains("169.254.169.254") == false)
    }

    @Test("a v4-only static NIC likewise leaves the v6 route to a later NIC")
    func v4OnlyStaticNICDoesNotConsumeTheIPv6MetadataClaim() {
        let attachments = [
            ResolvedNetworkAttachment(
                network: "v4-only",
                attachment: .tap(interface: "tapA"),
                macAddress: "52:54:00:00:00:01",
                ipAddress: "192.168.1.5",
                netmask: "255.255.255.0",
                metadataEnabled: true
            ),
            ResolvedNetworkAttachment(
                network: "dual-stack",
                attachment: .tap(interface: "tapB"),
                macAddress: "52:54:00:00:00:02",
                ipAddress: "10.10.0.5",
                netmask: "255.255.255.0",
                ip6Address: "fd12:3456:789a::100",
                prefixLength6: 64,
                metadataEnabled: true
            ),
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        // v4 rendered once, on the NIC that got there first...
        #expect(yaml?.components(separatedBy: "169.254.169.254/32").count == 2)
        // ...and v6 on the first NIC that actually has an address for it.
        #expect(yaml?.components(separatedBy: "fd00:ec2::254/128").count == 2)
    }

    @Test("two dual-stack NICs render exactly one v6 metadata route")
    func dualStackNICsRenderOneIPv6MetadataRoute() {
        // v6 has no option-121 backstop, so a duplicate here would be visible
        // to the guest rather than absorbed by the DHCP path.
        let attachments = (1...2).map { index in
            ResolvedNetworkAttachment(
                network: "net\(index)",
                attachment: .tap(interface: "tap\(index)"),
                macAddress: "52:54:00:00:00:0\(index)",
                ipAddress: "10.\(index).0.5",
                netmask: "255.255.255.0",
                ip6Address: "fd12:3456:789a::10\(index)",
                prefixLength6: 64,
                metadataEnabled: true
            )
        }

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.components(separatedBy: "fd00:ec2::254/128").count == 2)
        #expect(yaml?.components(separatedBy: "169.254.169.254/32").count == 2)
    }

    @Test("a NIC skipped for want of an address does not consume the metadata claim")
    func skippedNICDoesNotConsumeTheMetadataClaim() {
        // The static branch drops a NIC with no allocation before it renders
        // anything, so claiming the route on it would lose it entirely.
        let attachments = [
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tapA"),
                macAddress: "52:54:00:00:00:01",
                metadataEnabled: true
            ),
            ResolvedNetworkAttachment(
                network: "default",
                attachment: .tap(interface: "tapB"),
                macAddress: "52:54:00:00:00:02",
                ipAddress: "10.10.0.5",
                netmask: "255.255.255.0",
                metadataEnabled: true
            ),
        ]

        let yaml = CloudInitProvisioner.networkConfigYAML(for: attachments)
        #expect(yaml?.contains("- to: 169.254.169.254/32") == true)
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
