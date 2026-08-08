import Foundation
import StratoShared

/// Builds the network portion of a sandbox's wire spec (issue #416). Sandboxes
/// carry at most one NIC, so this yields a single `NetworkSpec` rather than the
/// list `VMSpecBuilder` produces; the field mapping itself is shared with the VM
/// path via `NetworkSpec.build` (issue #597).
enum SandboxSpecBuilder {
    /// Whether sandbox NICs go on the wire at all.
    ///
    /// Agents can now realize one end to end: STR-100 attaches a veth + TAP
    /// into the jail's network namespace and binds it to OVN, and STR-101 has
    /// the guest configure the interface from the config drive's `network`
    /// block. One thing still gates the wire: this flag is fleet-wide, while
    /// the capability is per-agent. An agent that is unjailed, non-Linux, too
    /// old, or paired with a pre-schema-v2 guest image cannot realize a sandbox
    /// NIC and would fail every placement it received. STR-103 replaces this
    /// constant with that per-agent gate, and is what flips it.
    ///
    /// Meanwhile the sandbox's interface row, its IPAM allocation, and its
    /// security-group membership all exist control-plane-side: the address
    /// stays reserved and stable, but the wire spec omits the NetworkSpec so
    /// the sandbox can actually boot.
    ///
    /// Membership is the one of those three that is *partly* observable on the
    /// wire (STR-102). The per-NIC ids ride inside this NetworkSpec and are
    /// therefore withheld with it — but the *groups* a sandbox NIC attaches
    /// are seeded into `DesiredStateMessage.securityGroups` regardless, so a
    /// topology authority realizes their port groups and ACLs before any
    /// sandbox port exists to join them. That is deliberate: it means flipping
    /// this flag does not also become the moment those port groups are first
    /// created, which would park every first sandbox create on
    /// `DependencyPendingError`.
    static let guestNetworkingSupported = false

    /// Builds the NetworkSpec for a sandbox's NIC, or nil when the sandbox has
    /// no interface (or guest networking is not yet supported — see
    /// `guestNetworkingSupported`). `interface.addresses` must be eager-loaded —
    /// the per-family address rows are the source of NIC addressing.
    ///
    /// `network` is the row the NIC's foreign key points at, supplying the name
    /// and the DHCP/DNS configuration agents program into OVN. Nil means the
    /// assembly could not load it, which yields no spec at all rather than a
    /// half-configured NIC.
    ///
    /// `securityGroupIds` is the NIC's membership, from
    /// `SandboxInterfaceSecurityGroup` (STR-102) — same contract as the VM
    /// path, already gated on the receiving agent's protocol version by the
    /// assembly. It is resolved and passed even while `guestNetworkingSupported`
    /// is false, so the flip is a one-line change rather than a new code path.
    ///
    /// `sendsMetadataPort` gates `metadataEnabled` on the receiving agent's protocol
    /// version (STR-49), as on the VM path.
    static func networkSpec(
        from interface: SandboxNetworkInterface?,
        network: LogicalNetwork?,
        securityGroupIds: [UUID]? = nil,
        sendsMetadataPort: Bool = true,
        siteResolverCapable: Bool? = true
    ) -> NetworkSpec? {
        guard guestNetworkingSupported, let interface, let network else { return nil }
        return NetworkSpec.build(
            interface: interface, network: network, securityGroupIds: securityGroupIds,
            sendsMetadataPort: sendsMetadataPort,
            siteResolverCapable: siteResolverCapable)
    }
}
