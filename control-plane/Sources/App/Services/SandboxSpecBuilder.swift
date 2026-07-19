import Foundation
import StratoShared

/// Builds the network portion of a sandbox's wire spec (issue #416). Sandboxes
/// carry at most one NIC, so this yields a single `NetworkSpec` rather than the
/// list `VMSpecBuilder` produces, but the field mapping is identical — the
/// agent realizes a sandbox attachment through the same OVN/user-mode paths as
/// a VM NIC.
enum SandboxSpecBuilder {
    /// Whether sandbox NICs go on the wire at all. The v1 guest image has no
    /// in-guest networking — the init never brings up eth0 and the guest kernel
    /// has no IP autoconfiguration — so both sandbox runtimes refuse any spec
    /// with a non-nil network (`SandboxRuntimeError.networkingUnsupported`)
    /// rather than mis-converge. Until the guest image learns to configure its
    /// NIC, the sandbox's interface row and its IPAM allocation exist only
    /// control-plane-side: the address stays reserved and stable, but the wire
    /// spec omits the NetworkSpec so the sandbox can actually boot. Flip this
    /// when guest networking lands.
    static let guestNetworkingSupported = false

    /// Builds the NetworkSpec for a sandbox's NIC, or nil when the sandbox has
    /// no interface (or guest networking is not yet supported — see
    /// `guestNetworkingSupported`). `interface.addresses` must be eager-loaded —
    /// the per-family address rows are the source of NIC addressing.
    ///
    /// `network` supplies the DHCP/DNS configuration agents program into OVN;
    /// nil (network row absent) leaves DHCP disabled, matching the VM path.
    static func networkSpec(
        from interface: SandboxNetworkInterface?,
        network: LogicalNetwork?
    ) -> NetworkSpec? {
        guard guestNetworkingSupported, let interface else { return nil }
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
