import Foundation

/// The addresses an instance metadata service answers on, inside the guest.
///
/// One definition because four issues reference them: the OVN `localport` that
/// materializes them on every logical switch (STR-49), the routes advertised to
/// guests so the addresses are reachable at all (STR-53), the implicit
/// security-group egress allow (STR-54), and the listener itself (STR-56).
///
/// Both are the de-facto addresses guest tooling already probes — cloud-init's
/// Ec2 datasource tries `http://169.254.169.254` and `http://[fd00:ec2::254]`
/// without configuration — which is the entire reason for adopting someone
/// else's numbers rather than picking our own.
public enum InstanceMetadataEndpoint {
    /// The IPv4 endpoint, link-local per RFC 3927.
    public static let address = "169.254.169.254"
    /// `address` as a host CIDR, the form the agent assigns to its namespace
    /// interface.
    public static let cidr = "169.254.169.254/32"

    /// The IPv6 endpoint: a ULA, not a link-local.
    ///
    /// A link-local (`fe80::a9fe:a9fe`) would always be on-link and need no
    /// advertised route, but nothing in any guest looks for it, and OVN already
    /// synthesizes an EUI-64 link-local for ports carrying IPv6 — adding a
    /// second one invites a conflict for a reachability win no guest can use.
    public static let addressV6 = "fd00:ec2::254"
    /// `addressV6` as a host CIDR.
    public static let cidrV6 = "fd00:ec2::254/128"

    /// The TCP port the service listens on, both families.
    public static let port = 80

    /// Both endpoints, v4 first — the order the OVN `addresses` column and the
    /// agent's namespace interface both use.
    public static let addresses = [address, addressV6]
}
