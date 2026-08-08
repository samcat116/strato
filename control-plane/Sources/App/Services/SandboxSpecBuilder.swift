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
    /// `securityGroupIds` is the NIC's membership, from
    /// `SandboxInterfaceSecurityGroup` (STR-102) — same contract as the VM
    /// path, already gated on the receiving agent's protocol version by the
    /// assembly.
    ///
    /// `sendsMetadataPort` gates `metadataEnabled` on the receiving agent's protocol
    /// version (STR-49), as on the VM path.
    ///
    /// `agentRealizesSandboxNICs` is the per-agent gate that replaced this
    /// type's old fleet-wide `guestNetworkingSupported` constant (STR-103).
    /// It is the receiving agent's advertised sandbox-networking capability:
    /// OVN, the jailer barrier the NIC's namespace belongs to, and a guest
    /// image whose init configures the interface from the config drive — none
    /// of which any wire version implies, since the guest image is installed
    /// separately from the agent binary.
    ///
    /// Withholding on a `false` is what makes the flag's arrival safe rather
    /// than a fleet-wide outage. Sandbox NICs have been *allocated* since issue
    /// #416 while never reaching the wire, so the first sync after this change
    /// would otherwise hand a NIC to every sandbox on every host at once —
    /// including hosts whose guest image predates the config drive's `network`
    /// block, which refuse such a document and would fail every sandbox create
    /// permanently. Placement (`SchedulerService`) keeps *new* networked
    /// sandboxes off those hosts; this keeps the NIC off the wire for the ones
    /// already there.
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
