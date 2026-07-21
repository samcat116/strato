import Foundation

/// What the QEMU guest agent (qga) reported about a running VM's guest OS,
/// attached to that VM's `ObservedVMState` on the agent → control-plane
/// observed-state report (issue #563).
///
/// This is a best-effort, informational channel, not a source of truth: qga is
/// *unresponsive whenever the guest is not running the agent*, so the whole
/// struct is absent (`ObservedVMState.guestInfo == nil`) for VMs whose image
/// lacks qga, whose guest is still booting, or whose guest hung — and every
/// field within it is independently optional for the same reason. Readers must
/// tolerate a missing struct and missing pieces rather than assume a complete
/// record.
///
/// The observed addresses here are deliberately distinct from a VM's
/// *allocated* addresses (IPAM's static assignment, or nothing at all on
/// DHCP/SLIRP): only qga can see what the guest actually configured — DHCP
/// leases, manual changes, IPv6 SLAAC addresses — so these are the sole way
/// those addresses become visible to the control plane.
public struct GuestInfo: Codable, Sendable, Equatable {
    /// Whether the guest agent answered at all during the last probe. `true`
    /// means a `guest-ping`/`guest-sync` round-trip succeeded within its
    /// budget; the address/hostname fields are only meaningful when this is
    /// `true`. A VM with no qga never produces a `GuestInfo` at all, so in
    /// practice this is `true` on every reported struct — it exists so the
    /// control plane can still record a positive liveness signal even when the
    /// follow-up detail queries came back empty.
    public let qgaAvailable: Bool

    /// The guest OS hostname (`guest-get-host-name`), or nil if the guest could
    /// not report one.
    public let hostname: String?

    /// The network interfaces the guest actually has configured
    /// (`guest-network-get-interfaces`), keyed for the control plane by each
    /// interface's hardware (MAC) address so it can be matched against the
    /// VM's `VMNetworkInterface` rows. Empty when the guest reported no
    /// interfaces or the query failed.
    public let interfaces: [GuestNetworkInterface]

    public init(
        qgaAvailable: Bool,
        hostname: String? = nil,
        interfaces: [GuestNetworkInterface] = []
    ) {
        self.qgaAvailable = qgaAvailable
        self.hostname = hostname
        self.interfaces = interfaces
    }
}

/// One network interface as seen *inside the guest* by qga
/// (`guest-network-get-interfaces`). Distinct from `VMNetworkInterface`, which
/// is the control plane's own record of the NIC it attached: this is what the
/// guest OS reports it did with that NIC.
public struct GuestNetworkInterface: Codable, Sendable, Equatable {
    /// The guest's name for the interface, e.g. "eth0", "enp0s3", "lo".
    public let name: String

    /// The interface's hardware (MAC) address, lowercased and colon-separated
    /// (e.g. "52:54:00:12:34:56"), or nil for interfaces the guest reported
    /// without one (notably loopback). This is the join key the control plane
    /// uses to attribute observed addresses to a `VMNetworkInterface`.
    public let hardwareAddress: String?

    /// The addresses the guest has configured on this interface. Includes
    /// DHCP/SLAAC/link-local addresses the control plane never allocated, which
    /// is the whole point — nil-nothing here means the guest reported none.
    public let addresses: [GuestIPAddress]

    public init(name: String, hardwareAddress: String? = nil, addresses: [GuestIPAddress] = []) {
        self.name = name
        self.hardwareAddress = hardwareAddress
        self.addresses = addresses
    }
}

/// One IP address configured inside the guest, as reported by qga.
public struct GuestIPAddress: Codable, Sendable, Equatable {
    /// The address family this address belongs to.
    public let family: IPFamily

    /// The address in its canonical text form (no prefix suffix), e.g.
    /// "192.168.1.42" or "fe80::5054:ff:fe12:3456".
    public let address: String

    /// The prefix length (CIDR bits) the guest reported for this address, or
    /// nil if qga did not supply one.
    public let prefixLength: Int?

    public init(family: IPFamily, address: String, prefixLength: Int? = nil) {
        self.family = family
        self.address = address
        self.prefixLength = prefixLength
    }
}
