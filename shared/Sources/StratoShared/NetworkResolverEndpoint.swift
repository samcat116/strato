import Foundation

/// The addresses a network's built-in DNS resolver answers on, inside the guest.
///
/// One definition because four things reference them: the OVN `localport` that
/// materializes them on every logical switch (STR-40, the same port that already
/// carries `InstanceMetadataEndpoint`), the routes advertised to guests so the
/// addresses are reachable at all, the implicit security-group egress allow, and
/// the CoreDNS the agent runs in the network's chassis namespace.
///
/// Both are AWS's numbers for the same service — `169.254.169.253` and
/// `fd00:ec2::253` are the addresses the Amazon-provided VPC resolver answers on
/// — adopted for `InstanceMetadataEndpoint`'s reason: operator muscle memory and
/// guest tooling already know them, and inventing our own buys nothing.
///
/// ## Why one address rather than one per network
///
/// The resolver terminates in the *per-network* chassis namespace built for
/// instance metadata (`strato-md-<network-uuid>`, ADR 0003), so the namespace
/// already disambiguates which network asked and already routes replies back to
/// an overlapping tenant address. A distinct address per network would only be
/// needed to recover that identity in a *shared* namespace; here it would buy
/// nothing and cost an allocation, a column, and a per-network security-group
/// match instead of a constant one. See ADR 0006.
public enum NetworkResolverEndpoint {
    /// The IPv4 endpoint, link-local per RFC 3927.
    public static let address = "169.254.169.253"
    /// `address` as a host CIDR, the form the agent assigns to its namespace
    /// interface.
    public static let cidr = "169.254.169.253/32"

    /// The IPv6 endpoint: a ULA, not a link-local, for the same reason
    /// `InstanceMetadataEndpoint.addressV6` is one — nothing in any guest looks
    /// for a link-local resolver, and OVN already synthesizes an EUI-64
    /// link-local for ports carrying IPv6.
    public static let addressV6 = "fd00:ec2::253"
    /// `addressV6` as a host CIDR.
    public static let cidrV6 = "fd00:ec2::253/128"

    /// The port the service listens on, both families and both transports. DNS
    /// falls back to TCP when a reply is truncated, so anything gating this
    /// service has to cover both.
    public static let port = 53

    /// Both endpoints, v4 first — the order the OVN `addresses` column and the
    /// agent's namespace interface both use.
    public static let addresses = [address, addressV6]
}
