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
    public static func v4Options(
        gateway: String, dnsServers: [String], domainName: String?, leaseTime: Int?, subnet: String
    ) -> [String: String] {
        var options: [String: String] = [
            "server_id": gateway,
            "server_mac": serverMAC(for: subnet),
            "lease_time": String(leaseTime ?? 3600),
            "router": gateway,
        ]
        let cleanedDNS =
            dnsServers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { IPv4Address($0) != nil }
        if !cleanedDNS.isEmpty {
            options["dns_server"] = "{\(cleanedDNS.joined(separator: ", "))}"
        }
        if let domainName, !domainName.isEmpty {
            options["domain_name"] = "\"\(domainName)\""
        }
        return options
    }

    /// Builds the OVN DHCPv6 option map. OVN keys the family off the
    /// `DHCP_Options` row's CIDR, and the v6 grammar is smaller: `server_id`
    /// is a MAC (it seeds the server DUID — never an IP, unlike v4), DNS is
    /// the option's v6 entries, and the search domain is `domain_search`.
    /// There is deliberately no router option: guests learn their default
    /// route from Router Advertisements (`ipv6_ra_configs` on the router
    /// port), not DHCPv6.
    public static func v6Options(
        dnsServers: [String], domainName: String?, subnet6: String
    ) -> [String: String] {
        var options: [String: String] = [
            "server_id": serverMAC(for: subnet6)
        ]
        let v6DNS =
            dnsServers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { IPv6Address($0) != nil }
        if !v6DNS.isEmpty {
            options["dns_server"] = "{\(v6DNS.joined(separator: ", "))}"
        }
        if let domainName, !domainName.isEmpty {
            options["domain_search"] = "\"\(domainName)\""
        }
        return options
    }

    /// A stable locally-administered unicast MAC derived from the subnet, so the
    /// DHCP server identity doesn't churn between reconciliations (FNV-1a).
    public static func serverMAC(for subnet: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603  // FNV-1a offset basis
        for byte in subnet.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
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

    /// Whether a row predates `network-id` stamping and can be adopted as this
    /// network's row for `cidr`.
    ///
    /// Adoption — rather than leaving the row orphaned and creating a fresh one
    /// — matters because existing VM ports still reference the old row through
    /// their `dhcpv4_options` column: guests would keep leasing from a row no
    /// later edit ever reaches. Updating it in place keeps the OVSDB row UUID,
    /// so live port bindings stay valid (the same argument `ensureSwitch` makes
    /// for renaming a legacy switch).
    ///
    /// Unambiguous by construction: names were globally unique when any such
    /// row was written, so at most one legacy row can match.
    public static func isAdoptableLegacy(
        _ externalIDs: [String: String]?, rowCIDR: String, cidr: String, networkName: String
    ) -> Bool {
        rowCIDR == cidr
            && externalIDs?[managedKey] == managedValue
            && externalIDs?[networkIDKey] == nil
            && externalIDs?[networkNameKey] == networkName
    }

    /// Whether a row is a legacy managed row this network owns, at any CIDR —
    /// what a DHCP-disable teardown must also remove, or a network disabled
    /// before its first post-upgrade converge would keep answering leases.
    public static func isLegacyOwned(_ externalIDs: [String: String]?, networkName: String) -> Bool {
        externalIDs?[managedKey] == managedValue
            && externalIDs?[networkIDKey] == nil
            && externalIDs?[networkNameKey] == networkName
    }

    /// Lowercased, matching `OVNNaming`'s treatment of ids in object names.
    private static func canonical(_ networkId: UUID) -> String {
        networkId.uuidString.lowercased()
    }
}
