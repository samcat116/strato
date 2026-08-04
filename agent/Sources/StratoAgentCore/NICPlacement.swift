import Foundation

/// Where on this host a workload's NIC is realized, and what OVN calls its port.
///
/// A VM's VMM runs in the host network namespace, so its TAP can live there too
/// and be plugged straight into the OVN integration bridge. A jailed sandbox's
/// Firecracker runs chrooted inside `strato-sbx-<id>` with `CAP_NET_ADMIN`
/// dropped (see `SandboxJailPlan`), and its only network backend is a TAP opened
/// *by name from inside the jail* — no fd passing, no vhost-user. So the device
/// genuinely has to exist in that namespace, owned by the jail's uid, and the
/// path that realizes it is a different one (issue STR-100).
///
/// This is a placement, not an attachment: both cases still resolve to
/// `NetworkAttachment.tap`, because the jailer enters the namespace via
/// `--netns` before Firecracker ever opens the device. The namespace is
/// implicit to the VMM; it is only the *realization* that differs.
public enum NICPlacement: Sendable, Equatable {
    /// A VM: TAP in the host namespace, on `br-int`, OVN port `vm-<id>[-n]`.
    case virtualMachine
    /// A jailed sandbox: a veth pair straddles the namespace with its host end
    /// on `br-int`, and a TAP inside the namespace owned by the jail uid is
    /// spliced to the veth peer with `tc` redirects. OVN port `sbx-<id>[-n]`.
    ///
    /// The plain "create the TAP in the host namespace and move it in" recipe
    /// was measured and does not work: within 30ms of the move OVS reports
    /// `ofport: -1` and `error: "could not open network device"`, and
    /// `ovn-controller` releases the `Port_Binding` — while the OVSDB rows
    /// survive untouched, so the failure is invisible to a check that looks the
    /// port up by name (STR-99).
    case sandboxNetns(netnsName: String, ownerUID: UInt32, ownerGID: UInt32)

    /// The namespace this NIC's device lives in, or nil for the host namespace.
    public var netnsName: String? {
        switch self {
        case .virtualMachine: return nil
        case .sandboxNetns(let name, _, _): return name
        }
    }
}
