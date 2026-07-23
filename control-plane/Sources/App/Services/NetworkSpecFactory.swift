import Foundation
import StratoShared

extension NetworkSpec {
    /// Builds the wire spec for one NIC. VMs and sandboxes share this mapping
    /// verbatim (issue #597) — a sandbox attachment is realized through the same
    /// OVN/user-mode paths as a VM NIC — so both spec builders funnel through here
    /// rather than keeping their own copies of the field-for-field construction.
    ///
    /// `interface.addresses` must be eager-loaded: the per-family address rows are
    /// the source of NIC addressing (the legacy single-address columns are dead).
    /// `network` supplies the DHCP/DNS configuration agents program into OVN; nil
    /// (network row absent) leaves DHCP disabled.
    /// `securityGroupIds` is the NIC's security-group membership (VM NICs
    /// only; sandbox NICs pass nil = unmanaged), already gated on the
    /// receiving agent's protocol version by the assembly.
    static func build(
        interface: some NetworkAddressable, network: LogicalNetwork?, securityGroupIds: [UUID]? = nil
    ) -> NetworkSpec {
        let ipv4 = interface.ipv4Address
        let ipv6 = interface.ipv6Address
        return NetworkSpec(
            network: interface.network,
            // The network's id, so the agent names its OVN switch after the id
            // (not the user-chosen name) and lands the instance on the same switch
            // the network reconciler creates (issue #342).
            networkId: network?.id,
            macAddress: interface.macAddress,
            ipAddress: ipv4?.address,
            // Old agents still read a dotted netmask off the wire.
            netmask: interface.ipv4Netmask,
            gateway: ipv4?.gateway,
            ipv6Address: ipv6?.address,
            ipv6PrefixLength: ipv6?.prefixLength,
            gateway6: ipv6?.gateway,
            mtu: interface.mtu,
            dhcpEnabled: network?.dhcpEnabled ?? false,
            dnsServers: network?.dnsServers ?? [],
            domainName: network?.domainName,
            leaseTime: network?.leaseTime,
            securityGroupIds: securityGroupIds
        )
    }
}
