import Foundation

/// Deterministic, collision-resistant TAP interface name for a VM.
///
/// Linux caps network interface names at 15 characters (`IFNAMSIZ`), but a VM id
/// is a 36-character UUID, so the naïve `tap-<vmId>` (40 chars) is rejected by
/// `ip`/QEMU and never produced a working device. We instead derive a stable short
/// name — `"tap"` + 12 hex chars of an FNV-1a digest of the vmId — which is exactly
/// 15 characters.
///
/// The digest is a fixed FNV-1a (not Swift's `Hasher`, whose seed is randomized per
/// process) so the same vmId always maps to the same interface name across agent
/// restarts. This is what lets create and teardown agree on the device name.
///
/// This lives in `StratoAgentCore` (rather than the platform-gated
/// `NetworkServiceLinux`) so it is pure, portable, and unit-testable.
public func tapInterfaceName(for vmId: String) -> String {
    tapInterfaceName(for: vmId, nicIndex: 0)
}

/// Per-NIC variant of `tapInterfaceName(for:)`. NIC 0 keeps the historical
/// vmId-only digest so devices created by older agents are still found and torn
/// down; additional NICs mix the index into the digest input.
public func tapInterfaceName(for vmId: String, nicIndex: Int) -> String {
    interfaceName(prefix: "tap", workloadId: vmId, nicIndex: nicIndex)
}

/// The three devices a jailed sandbox's NIC needs (issue STR-100). All are
/// derived from the same digest as `tapInterfaceName(for:nicIndex:)`, so they
/// survive an agent restart and teardown can find them with no persisted state.
///
/// The veth pair straddles the namespace boundary: `vethHost` stays in the host
/// namespace on the OVN integration bridge, `vethPeer` is moved into the
/// sandbox's netns, and `tap` — created inside the netns, owned by the jail uid
/// — is spliced to the peer by `tc` redirects. See `SandboxNetnsAttachmentPlan`.
public struct SandboxNICDeviceNames: Sendable, Equatable {
    /// The TAP the jailed Firecracker opens by name, inside the netns.
    public let tap: String
    /// The veth end that stays in the host namespace, bound to `br-int`.
    public let vethHost: String
    /// The veth end that is moved into the sandbox's netns.
    public let vethPeer: String

    public init(tap: String, vethHost: String, vethPeer: String) {
        self.tap = tap
        self.vethHost = vethHost
        self.vethPeer = vethPeer
    }
}

/// Derives the device names for one NIC of a sandbox. Each is exactly 15
/// characters (`IFNAMSIZ`), which is why the prefixes are three characters and
/// not descriptive: the 12-hex digest consumes the rest of the budget.
public func sandboxNICDeviceNames(sandboxId: String, nicIndex: Int) -> SandboxNICDeviceNames {
    SandboxNICDeviceNames(
        tap: tapInterfaceName(for: sandboxId, nicIndex: nicIndex),
        vethHost: interfaceName(prefix: "vth", workloadId: sandboxId, nicIndex: nicIndex),
        vethPeer: interfaceName(prefix: "vtp", workloadId: sandboxId, nicIndex: nicIndex)
    )
}

/// The host-side name of the OVS internal interface that terminates a network's
/// metadata `localport` on this chassis (STR-49).
///
/// The logical switch port's name (`lsp-<uuid>-metadata`) cannot be reused: at
/// 41 characters it is far past `IFNAMSIZ`. Same digest scheme as the TAP and
/// veth names, so it survives an agent restart and teardown can rederive it with
/// no persisted state. There is exactly one such device per network per chassis,
/// so there is no NIC index to mix in.
public func chassisServiceInterfaceName(networkId: String) -> String {
    interfaceName(prefix: "mdp", workloadId: networkId, nicIndex: 0)
}

/// `<prefix>` + 12 hex chars of the FNV-1a digest of the NIC's identity. NIC 0
/// digests the bare workload id (the historical input, so pre-multi-NIC devices
/// are still found); later NICs mix the index in.
private func interfaceName(prefix: String, workloadId: String, nicIndex: Int) -> String {
    let input = nicIndex == 0 ? workloadId : "\(workloadId)#\(nicIndex)"
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a 64-bit offset basis
    for byte in input.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3  // FNV-1a 64-bit prime
    }
    let hex = String(format: "%012x", hash & 0xffff_ffff_ffff)
    return prefix + hex
}
