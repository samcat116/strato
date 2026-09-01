import Foundation
import StratoShared

/// Builds the network portion of a sandbox's wire spec (issue #416). Sandboxes
/// carry at most one NIC, so this yields a single `NetworkSpec` rather than the
/// list `VMSpecBuilder` produces; the field mapping itself is shared with the VM
/// path via `NetworkSpec.build` (issue #597).
enum SandboxSpecBuilder {
    /// Builds the NetworkSpec for a sandbox's NIC, or nil when the sandbox has
    /// no interface or the receiving agent cannot realize one.
    /// `interface.addresses` must be eager-loaded — the per-family address rows
    /// are the source of NIC addressing.
    ///
    /// `network` is the row the NIC's foreign key points at, supplying the name
    /// and the DHCP/DNS configuration agents program into OVN. Nil means the
    /// assembly could not load it, which yields no spec at all rather than a
    /// half-configured NIC.
    ///
    /// `securityGroupIds` is the NIC's membership from
    /// `SandboxInterfaceSecurityGroup` (STR-102), using the same contract as VMs.
    /// `sendsMetadataPort` controls whether `metadataEnabled` is present.
    ///
    /// `agentRealizesSandboxNICs` is the receiving agent's advertised networking
    /// capability: OVN, the jailer barrier, and a guest image that configures the
    /// interface. Placement keeps new networked sandboxes off incapable hosts;
    /// this guard withholds the NIC if an existing host lacks the capability.
    static func networkSpec(
        from interface: SandboxNetworkInterface?,
        network: LogicalNetwork?,
        securityGroupIds: [UUID]? = nil,
        sendsMetadataPort: Bool = true,
        siteResolverCapable: Bool? = true,
        agentRealizesSandboxNICs: Bool
    ) -> NetworkSpec? {
        guard agentRealizesSandboxNICs, let interface, let network else { return nil }
        return NetworkSpec.build(
            interface: interface, network: network, securityGroupIds: securityGroupIds,
            sendsMetadataPort: sendsMetadataPort,
            siteResolverCapable: siteResolverCapable)
    }
}
