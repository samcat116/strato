import Foundation
import StratoShared

/// Builds the network portion of a sandbox's wire spec (issue #416). Sandboxes
/// carry at most one NIC, so this yields a single `NetworkSpec` rather than the
/// list `VMSpecBuilder` produces, but the field mapping is identical — the
/// agent realizes a sandbox attachment through the same OVN/user-mode paths as
/// a VM NIC.
enum SandboxSpecBuilder {
    /// Builds the NetworkSpec for a sandbox's NIC, or nil when the sandbox has
    /// no interface. `interface.addresses` must be eager-loaded — the per-family
    /// address rows are the source of NIC addressing.
    ///
    /// `network` supplies the DHCP/DNS configuration agents program into OVN;
    /// nil (network row absent) leaves DHCP disabled, matching the VM path.
    static func networkSpec(
        from interface: SandboxNetworkInterface?,
        network: LogicalNetwork?
    ) -> NetworkSpec? {
        guard let interface else { return nil }
        let ipv4 = interface.ipv4Address
        let ipv6 = interface.ipv6Address
        return NetworkSpec(
            network: interface.network,
            // The network's id, so the agent names its OVN switch after the id
            // (not the user-chosen name) and lands the sandbox on the same
            // switch the network reconciler creates (issue #342).
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
            leaseTime: network?.leaseTime
        )
    }
}
