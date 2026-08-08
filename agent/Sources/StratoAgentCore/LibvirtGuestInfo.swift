import Foundation
import Libvirt
import StratoShared

/// `virDomainGetGuestInfo` + `virDomainInterfaceAddresses` → `GuestInfo`.
///
/// The libvirt spelling of `QGAClient.collectGuestInfo` (issue #563), and it
/// reports the same thing from the same source: libvirt asks the guest agent
/// over the `org.qemu.guest_agent.0` channel the domain document binds, so what
/// reaches the control plane does not change with the driver — only who owns
/// the socket. The transport, framing and resync `QGAClient` implements are all
/// libvirtd's problem now.
///
/// Lives here rather than in the driver for the reason `LibvirtMemoryStats`
/// gives: `LibvirtService` links a hypervisor SDK and therefore has no unit
/// tests, while a mis-mapped address family or a dropped interface is invisible
/// until an operator wonders why a VM shows no IP.
public enum LibvirtGuestInfo {

    /// The typed-parameter field carrying the guest's hostname.
    /// `virDomainGetGuestInfo` flattens its whole reply into `field`/`value`
    /// pairs; with only `VIR_DOMAIN_GUEST_INFO_HOSTNAME` requested this is the
    /// single pair that comes back.
    static let hostnameField = "hostname"

    /// `virIPAddrType`.
    enum AddressFamily: Int32 {
        case ipv4 = 0
        case ipv6 = 1

        var family: IPFamily {
            switch self {
            case .ipv4: return .ipv4
            case .ipv6: return .ipv6
            }
        }
    }

    /// What to report for a guest, or nil when neither query answered.
    ///
    /// - Parameters:
    ///   - hostnameParams: the reply to `virDomainGetGuestInfo`, or nil when
    ///     that call failed.
    ///   - interfaces: the reply to `virDomainInterfaceAddresses`, or nil when
    ///     *that* call failed.
    ///
    /// The two are optional separately because they fail separately, and either
    /// one answering is a positive liveness signal worth reporting —
    /// `qgaAvailable` exists for exactly that case. Both nil means there is no
    /// usable agent, which is a normal outcome (a guest with none installed,
    /// or one still booting) and never an error.
    public static func parse(
        hostnameParams: [TypedParam]?, interfaces: [DomainInterface]?
    ) -> GuestInfo? {
        guard hostnameParams != nil || interfaces != nil else { return nil }

        var hostname: String?
        for param in hostnameParams ?? [] where param.field == hostnameField {
            if case .string(let value) = param.value { hostname = value }
        }

        return GuestInfo(
            qgaAvailable: true,
            // Empty is dropped to nil, matching the qga path: a guest that
            // reports "" has not told us its hostname.
            hostname: hostname.flatMap { $0.isEmpty ? nil : $0 },
            interfaces: (interfaces ?? []).map(networkInterface(from:)))
    }

    private static func networkInterface(from iface: DomainInterface) -> GuestNetworkInterface {
        GuestNetworkInterface(
            name: iface.name,
            hardwareAddress: GuestInfo.normalizeMAC(iface.hwaddr),
            // An address whose family this build does not recognise is dropped
            // rather than guessed: `virIPAddrType` is append-only upstream, and
            // reporting an address under the wrong family would have the
            // control plane match it against the wrong `VMNetworkInterface`.
            addresses: iface.addrs.compactMap(ipAddress(from:)))
    }

    private static func ipAddress(from addr: DomainIPAddr) -> GuestIPAddress? {
        guard let family = AddressFamily(rawValue: addr.type) else { return nil }
        let text = addr.addr.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return GuestIPAddress(
            family: family.family, address: text,
            // libvirt reports the prefix as an unsigned count; a value that
            // cannot be a prefix length is reported as absent rather than
            // passed through.
            prefixLength: Int(exactly: addr.prefix).flatMap { $0 <= 128 ? $0 : nil })
    }
}
