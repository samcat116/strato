import Foundation

/// The addresses a network's built-in DNS resolver answers on, inside the guest.
///
/// **One distinct pair per network**, derived from a single index the control
/// plane allocates and stores on the network row. That is what makes the
/// resolver reachable from the *host* namespace, and reaching it from there is
/// what makes it able to forward: a resolver inside the tenant network's own
/// chassis namespace has only link-local addresses and no egress the OVN router
/// will SNAT, so it can answer for the zones it holds and nothing else. See
/// ADR 0008.
///
/// One definition because four things reference it: the OVN `localport` that
/// materializes the pair on the network's logical switch, the routes advertised
/// to guests so the addresses are reachable at all, the implicit security-group
/// egress allow, and the host-wide CoreDNS that binds one server block per pair.
///
/// ## Why an index rather than two stored addresses
///
/// The index *is* the allocation — a single small integer to lock, scan and keep
/// unique — and both addresses are pure functions of it. Storing the addresses
/// instead would mean two columns that can disagree, and a v6 scheme that could
/// never be changed without a data migration. The derivation lives here so the
/// control plane and the agent cannot drift on it, even though only the control
/// plane allocates.
public enum NetworkResolverEndpoint {
    /// The first index handed out, and the lowest that yields a usable address.
    ///
    /// RFC 3927 reserves `169.254.0.0/24` and `169.254.255.0/24`, so the usable
    /// v4 space is `169.254.1.0`–`169.254.254.255`. Starting at 256 puts the
    /// first network on `169.254.1.0` and makes the index's two octets read
    /// directly out of the address, which is what an operator staring at
    /// `ip rule` on a busy hypervisor actually needs.
    public static let firstIndex = 256

    /// The last usable index (`169.254.254.255`).
    public static let lastIndex = 65_279

    /// Indexes that would derive an address something else already owns.
    ///
    /// The instance metadata service sits at `169.254.169.254`, which is inside
    /// the allocatable range — so without this a network would eventually be
    /// handed the metadata address, and its guests' DNS queries would arrive at
    /// a namespace serving HTTP. `169.254.169.253` is reserved beside it: it was
    /// the resolver's well-known address before each network got its own, and a
    /// host mid-upgrade may still have an interface holding it.
    public static let reservedIndexes: Set<Int> = [
        (169 << 8) | 254,  // 169.254.169.254 — instance metadata
        (169 << 8) | 253,  // 169.254.169.253 — the pre-STR-40 resolver constant
    ]

    /// Whether `index` is one this allocator may hand out.
    public static func isValidIndex(_ index: Int) -> Bool {
        (firstIndex...lastIndex).contains(index) && !reservedIndexes.contains(index)
    }

    /// This network's IPv4 resolver address, link-local per RFC 3927.
    ///
    /// Allocated **sequentially rather than hashed** from the network id: ~65k
    /// usable addresses means birthday collisions appear at a few hundred
    /// networks, which is well inside what a single deployment reaches.
    public static func address(forIndex index: Int) -> String {
        "169.254.\((index >> 8) & 0xff).\(index & 0xff)"
    }

    /// This network's IPv6 resolver address.
    ///
    /// A ULA rather than a link-local, for `InstanceMetadataEndpoint`'s reason:
    /// nothing in a guest looks for a link-local resolver, and OVN already
    /// synthesizes an EUI-64 link-local for ports carrying IPv6. Drawn from
    /// `fd00:ec2:1::/48` so it is disjoint from the instance metadata service's
    /// `fd00:ec2::/64` — the two are neighbours in one `/32`, which is what lets
    /// a single security-group carve-out cover both.
    public static func addressV6(forIndex index: Int) -> String {
        "fd00:ec2:1::\(String(index, radix: 16))"
    }

    /// `address` as a host CIDR, the form the agent assigns to its interface.
    public static func cidr(forIndex index: Int) -> String { "\(address(forIndex: index))/32" }
    /// `addressV6` as a host CIDR.
    public static func cidrV6(forIndex index: Int) -> String { "\(addressV6(forIndex: index))/128" }

    /// The whole v4 space these addresses are drawn from.
    ///
    /// The security-group carve-out matches this rather than each network's
    /// address: a per-network match would mean a per-network port group, "a
    /// whole new object lifetime" as the metadata carve-out's doc comment puts
    /// it, for a rule that has to land on every managed port anyway. The range
    /// is link-local and unroutable, and the only things Strato puts in it are
    /// these resolvers and the metadata service.
    public static let v4Space = "169.254.0.0/16"

    /// The whole v6 space, covering the metadata address as well as every
    /// resolver — which is why one carve-out per protocol suffices.
    public static let v6Space = "fd00:ec2::/32"

    /// The port the service listens on, both families and both transports. DNS
    /// falls back to TCP when a reply is truncated, so anything gating this
    /// service has to cover both.
    public static let port = 53

    /// The routing table a network's resolver replies are routed by, in the
    /// host namespace.
    ///
    /// Derived from the index so it is stable across agent restarts and unique
    /// per network by construction. Offset well clear of the reserved ids
    /// (`local` 255, `main` 254, `default` 253) and of anything an operator is
    /// likely to have written by hand at a low number.
    public static func routingTable(forIndex index: Int) -> Int { 20_000 + index }
}
