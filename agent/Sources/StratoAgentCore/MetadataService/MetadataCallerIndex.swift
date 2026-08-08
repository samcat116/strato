import Foundation
import StratoShared

/// A request's source address, normalized so two spellings of one address are
/// one key.
public enum MetadataCallerAddress: Sendable, Hashable, CustomStringConvertible {
    case v4(IPv4Address)
    case v6(IPv6Address)

    /// Parses a bare address (no port, no zone id).
    ///
    /// An IPv4-mapped v6 address (`::ffff:10.0.0.5`) folds to the v4 case: a
    /// dual-stack socket reports a v4 peer that way, and an index that kept the
    /// two apart would fail to resolve exactly the callers it was built for.
    public init?(_ text: String) {
        if text.contains(":") {
            guard let v6 = IPv6Address(text) else { return nil }
            if v6.hi == 0, (v6.lo >> 32) == 0xffff {
                self = .v4(IPv4Address(raw: UInt32(truncatingIfNeeded: v6.lo)))
            } else {
                self = .v6(v6)
            }
            return
        }
        guard let v4 = IPv4Address(text) else { return nil }
        self = .v4(v4)
    }

    public var description: String {
        switch self {
        case .v4(let address): return address.description
        case .v6(let address): return address.description
        }
    }
}

/// Who a request came from, or why that could not be decided.
public enum MetadataCallerResolution: Sendable, Equatable {
    case vm(UUID)
    /// No instance this listener serves holds that address.
    case unknown
    /// Two live instances claim it. Never resolved by picking one.
    case ambiguous(vmIds: [UUID])
}

/// `source address → vmId` for one network's listener (STR-56).
///
/// ## Why the source address, and why this is not IPAM
///
/// ADR 0003 settles the identification question: one namespace per (chassis,
/// network) means a listener already knows which network it serves, and within
/// one network the source address identifies the caller. It is sound only
/// because VM logical switch ports carry `port_security`
/// (`NetworkServiceLinux.portSecurityEntry`), which pins each port to its
/// allocated MAC and addresses — the load-bearing precondition the ADR records
/// precisely because nothing in this file can reference it.
///
/// The keys come from the served metadata's own `MetadataNIC` entries rather
/// than from any allocation table, so an authentication decision never depends
/// on a second source of truth agreeing with the first. If the metadata says an
/// instance is `10.0.0.5`, that is exactly the instance the listener will serve
/// to `10.0.0.5`, and there is no third value that could disagree with either.
///
/// ## Ambiguity is refused
///
/// An address claimed by two instances resolves to `.ambiguous`, never to one of
/// them. This is the failure ADR 0003 names — "handing instance A's SSH keys and
/// identity to instance B is the failure mode, and it is silent" — arriving
/// through the store rather than through a shared namespace, and it is reachable
/// in ordinary operation: a VM is deleted, IPAM hands its address to the next
/// one, and the withdrawal has not landed on this host yet. First-wins and
/// last-wins are both a guess, and the guess is wrong half the time.
public struct MetadataCallerIndex: Sendable {
    private let byAddress: [MetadataCallerAddress: [UUID]]

    /// The network this index answers for — every key comes from a NIC on it.
    public let networkId: UUID

    public init(networkId: UUID, instances: [InstanceMetadata]) {
        self.networkId = networkId
        var byAddress: [MetadataCallerAddress: Set<UUID>] = [:]
        for instance in instances {
            for nic in instance.nics where nic.networkId == networkId {
                for address in Self.addresses(of: nic) {
                    byAddress[address, default: []].insert(instance.instanceId)
                }
            }
        }
        self.byAddress = byAddress.mapValues { $0.sorted { $0.uuidString < $1.uuidString } }
    }

    public func resolve(_ source: MetadataCallerAddress) -> MetadataCallerResolution {
        guard let claimants = byAddress[source] else { return .unknown }
        if claimants.count == 1 { return .vm(claimants[0]) }
        return .ambiguous(vmIds: claimants)
    }

    /// Every address a guest may legitimately send from on this NIC.
    private static func addresses(of nic: MetadataNIC) -> [MetadataCallerAddress] {
        var addresses: [MetadataCallerAddress] = []
        if let ipAddress = nic.ipAddress, let v4 = IPv4Address(ipAddress) {
            addresses.append(.v4(v4))
        }
        if let ipv6Address = nic.ipv6Address, let v6 = IPv6Address(ipv6Address) {
            // Through the parser rather than by string, so a non-canonical
            // spelling on the wire still matches what the kernel reports.
            addresses.append(.v6(v6))
        }
        // The EUI-64 link-local the guest derives from its own MAC. It should
        // not come up — a guest with no global address cannot reach a ULA
        // destination — but it is free to derive and it is *already inside*
        // OVN's `port_security` (see `IPv6Address.linkLocalEUI64`), so it is
        // exactly as unspoofable as the allocated addresses. Including it costs
        // three lines; discovering later that some guest's source-address
        // selection surprised us costs an outage.
        if let linkLocal = IPv6Address.linkLocalEUI64(fromMAC: nic.macAddress) {
            addresses.append(.v6(linkLocal))
        }
        return addresses
    }
}
