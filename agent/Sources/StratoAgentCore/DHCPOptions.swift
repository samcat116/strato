import Foundation
import StratoShared

/// Builds the OVN `DHCP_Options` `options` map and the DHCP server identity for
/// a subnet. Pure and platform-independent (no OVN dependency) so it lives in
/// the testable core; `NetworkServiceLinux` calls it when programming OVN.
public enum OVNDHCPOptionsBuilder {
    /// Builds the OVN DHCPv4 option map. `server_id`/`server_mac` are required for
    /// OVN to answer a DISCOVER; `router`/`dns_server`/`domain_name`/`lease_time`
    /// are the guest-facing config. DNS uses OVN's `{a, b}` set syntax and the
    /// domain is quoted per OVN's option grammar. The DNS list may be mixed —
    /// only its IPv4 entries belong in a DHCPv4 option (v6 entries go to
    /// `v6Options`).
    ///
    /// `metadataEnabled` and `resolverEnabled` each add their address to option
    /// 121 (`classless_static_route`) so guests on a network publishing that
    /// service actually have a route to it — see `classlessStaticRoute`.
    ///
    /// `resolverEnabled` also **replaces** `dns_server`: the guest is told the
    /// network's own resolver and `dnsServers` becomes what that resolver
    /// forwards to (STR-40). The substitution happens here rather than control
    /// plane side so one field carries one meaning on the wire, and so an agent
    /// that degraded a NIC to user-mode can fall back to the raw list.
    public static func v4Options(
        gateway: String, dnsServers: [String], domainName: String?, leaseTime: Int?, subnet: String,
        metadataEnabled: Bool = false,
        resolverAddresses: [String] = []
    ) -> [String: String] {
        var options: [String: String] = [
            "server_id": gateway,
            "server_mac": serverMAC(for: subnet),
            "lease_time": String(leaseTime ?? 3600),
            "router": gateway,
        ]
        // The network's *own* resolver address, not a constant: every network
        // has a distinct pair so they can all be served from the host namespace.
        let resolverV4 = resolverAddresses.filter(IPFamily.ipv4.matches)
        let cleanedDNS =
            resolverV4.isEmpty
            ? dnsServers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter(IPFamily.ipv4.matches)
            : resolverV4
        if !cleanedDNS.isEmpty {
            options["dns_server"] = "{\(cleanedDNS.joined(separator: ", "))}"
        }
        if let domainName = wellFormedDomain(domainName) {
            options["domain_name"] = "\"\(domainName)\""
        }
        if metadataEnabled || !resolverV4.isEmpty {
            options["classless_static_route"] = classlessStaticRoute(
                gateway: gateway, metadata: metadataEnabled, resolver: resolverV4.first)
        }
        return options
    }

    /// DHCP option 121's route list: the IPv4 link-local service addresses this
    /// network publishes, on-link, plus this network's default route (STR-53,
    /// extended for the resolver by STR-40).
    ///
    /// **The default route is repeated here on purpose.** RFC 3442 requires a
    /// client that understands option 121 to ignore option 3 (`router`)
    /// entirely, so advertising only the service routes would hand every guest
    /// a path to the IMDS and take away its default gateway. `router` stays in
    /// the map for the clients that don't implement 121 — the two options are
    /// alternatives, never a merge.
    ///
    /// `0.0.0.0` as the next hop is RFC 3442's on-link encoding: the guest ARPs
    /// for the address itself, and OVN's ARP responder answers from the
    /// `localport`'s `addresses` (STR-49). On-link rather than via the gateway
    /// because there is nothing to route it *through* — the localport hangs off
    /// the logical switch, the logical router has no route to the address, and
    /// an isolated network has no router at all.
    ///
    /// The resolver route matters more than the metadata one here. Most Linux
    /// images carry a `169.254.0.0/16` link-local route that covers both by
    /// accident; where they don't, a missing metadata route costs the guest
    /// IMDS, while a missing resolver route costs it *all* name resolution.
    static func classlessStaticRoute(
        gateway: String, metadata: Bool = true, resolver: String? = nil
    ) -> String {
        var routes: [String] = []
        if metadata { routes.append("\(InstanceMetadataEndpoint.cidr),0.0.0.0") }
        if let resolver { routes.append("\(resolver)/32,0.0.0.0") }
        routes.append("0.0.0.0/0,\(gateway)")
        return "{\(routes.joined(separator: ", "))}"
    }

    /// Builds the OVN DHCPv6 option map. OVN keys the family off the
    /// `DHCP_Options` row's CIDR, and the v6 grammar is smaller: `server_id`
    /// is a MAC (it seeds the server DUID — never an IP, unlike v4), DNS is
    /// the option's v6 entries, and the search domain is `domain_search`.
    /// There is deliberately no router option: guests learn their default
    /// route from Router Advertisements (`ipv6_ra_configs` on the router
    /// port), not DHCPv6.
    ///
    /// There is likewise no route for either link-local service here, and no
    /// `metadataEnabled` parameter to take one: DHCPv6 has no counterpart to
    /// option 121, and the RA cannot carry an on-link route to `fd00:ec2::254`
    /// or `fd00:ec2::253` either (RFC 4191 route information is a route *via
    /// the advertising router*, which has no path to a localport on the switch).
    /// Those routes reach guests only through
    /// `CloudInitProvisioner.networkConfigYAML` — see STR-53.
    ///
    /// `resolverEnabled` still applies to `dns_server`, which DHCPv6 does
    /// carry: the guest is told the resolver's v6 address and `dnsServers`
    /// becomes that resolver's upstreams, exactly as in `v4Options`.
    public static func v6Options(
        dnsServers: [String], domainName: String?, subnet6: String,
        resolverAddresses: [String] = []
    ) -> [String: String] {
        var options: [String: String] = [
            "server_id": serverMAC(for: subnet6)
        ]
        let resolverV6 = resolverAddresses.filter(IPFamily.ipv6.matches)
        let v6DNS =
            resolverV6.isEmpty
            ? dnsServers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter(IPFamily.ipv6.matches)
            : resolverV6
        if !v6DNS.isEmpty {
            options["dns_server"] = "{\(v6DNS.joined(separator: ", "))}"
        }
        if let domainName = wellFormedDomain(domainName) {
            options["domain_search"] = "\"\(domainName)\""
        }
        return options
    }

    /// The domain to advertise, or nil when there is none to advertise safely.
    ///
    /// The control plane validates this on write (issue #876), so a malformed
    /// value here is a row that predates the validation. It is dropped rather
    /// than emitted because OVN's option grammar has no escape for it: a `"`
    /// ends the quoted value early and makes the whole `DHCP_Options` row
    /// unparseable, which costs *every* VM on the network its lease. Escaping
    /// is not the alternative — OVN's `str` parser strips the surrounding
    /// quotes without interpreting escapes, so a `\` would reach the guest as
    /// part of its domain. Degrading to "no search domain" is the failure worth
    /// having; "no DHCP" is not.
    private static func wellFormedDomain(_ domainName: String?) -> String? {
        guard let trimmed = domainName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return DNSNameSyntax.isValidDomainName(trimmed) ? trimmed : nil
    }

    /// A stable locally-administered unicast MAC derived from the subnet, so the
    /// DHCP server identity doesn't churn between reconciliations (FNV-1a).
    public static func serverMAC(for subnet: String) -> String {
        let hash = FNV1a.legacyStratoHash64(subnet)
        var octets = (0..<6).map { UInt8((hash >> (UInt64($0) * 8)) & 0xff) }
        octets[0] = (octets[0] & 0xFC) | 0x02  // locally administered, unicast
        return octets.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

/// Which `DHCP_Options` row belongs to which network.
///
/// Rows are matched on `(strato-managed, network-id, cidr)` — never on the CIDR
/// alone and never on the *name*. Two networks may legitimately share a prefix
/// (overlap checks are project-scoped) and, since issue #765, may also share a
/// name: names are unique only within a project. Matching on either would let
/// one project's DNS/lease edits land on another's row, and one project's
/// DHCP-disable delete the other's. Operator-created rows (no managed marker)
/// are never adopted.
///
/// Lives here rather than beside the OVN client because only `StratoAgentCore`
/// is unit-testable, and this is the rule the whole scheme rests on.
public enum DHCPRowIdentity {
    public static let managedKey = "strato-managed"
    public static let managedValue = "true"
    public static let networkIDKey = "network-id"
    /// Write-only human label, so `ovn-nbctl list dhcp_options` stays legible
    /// when every other column is a UUID. Nothing reads it.
    public static let networkNameKey = "network-name"

    /// The external-ids a managed row carries.
    public static func externalIDs(networkId: UUID, networkName: String) -> [String: String] {
        [
            networkIDKey: canonical(networkId),
            networkNameKey: networkName,
            managedKey: managedValue,
        ]
    }

    /// Whether a row is the one `networkId` owns for `cidr`.
    public static func isOwn(
        _ externalIDs: [String: String]?, rowCIDR: String, cidr: String, networkId: UUID
    ) -> Bool {
        rowCIDR == cidr
            && externalIDs?[networkIDKey] == canonical(networkId)
            && externalIDs?[managedKey] == managedValue
    }

    /// Lowercased, matching `OVNNaming`'s treatment of ids in object names.
    private static func canonical(_ networkId: UUID) -> String {
        networkId.uuidString.lowercased()
    }
}
