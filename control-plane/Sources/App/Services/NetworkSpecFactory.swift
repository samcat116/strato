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
    /// `network` is the row the NIC's FK points at — non-optional since issue
    /// #765, because a NIC cannot exist without one — and supplies both the
    /// display name and the DHCP/DNS configuration agents program into OVN.
    /// `securityGroupIds` is the NIC's security-group membership — VM and
    /// sandbox NICs alike since STR-102, resolved from whichever join table
    /// owns the NIC and already gated on the receiving agent's protocol version
    /// by the assembly. Nil is "unmanaged", never "no groups".
    ///
    /// `sendsMetadataPort` is the same kind of gate, for `metadataEnabled` (STR-49):
    /// false omits the field entirely for an agent that predates it, so nil on
    /// the wire always means "the sender has no opinion" rather than "off".
    static func build(
        interface: some NetworkAddressable, network: LogicalNetwork, securityGroupIds: [UUID]? = nil,
        sendsMetadataPort: Bool = true
    ) -> NetworkSpec {
        let ipv4 = interface.ipv4Address
        let ipv6 = interface.ipv6Address
        return NetworkSpec(
            // A human label only: names are unique per project, so they cannot
            // identify a network. Agents use it for logging and external-ids.
            network: network.name,
            // The network's id, so the agent names its OVN switch after the id
            // (not the user-chosen name) and lands the instance on the same switch
            // the network reconciler creates (issue #342). Taken from the NIC's
            // foreign key rather than `network.id`: same value by construction —
            // the caller looked the row up by it — but non-optional.
            networkId: interface.logicalNetworkID,
            macAddress: interface.macAddress,
            ipAddress: ipv4?.address,
            // Old agents still read a dotted netmask off the wire.
            netmask: interface.ipv4Netmask,
            gateway: ipv4?.gateway,
            ipv6Address: ipv6?.address,
            ipv6PrefixLength: ipv6?.prefixLength,
            gateway6: ipv6?.gateway,
            mtu: interface.mtu,
            dhcpEnabled: network.dhcpEnabled,
            dnsServers: network.dnsServers,
            domainName: network.domainName,
            leaseTime: network.leaseTime,
            securityGroupIds: securityGroupIds,
            metadataEnabled: sendsMetadataPort ? network.metadataEnabled : nil
        )
    }
}
