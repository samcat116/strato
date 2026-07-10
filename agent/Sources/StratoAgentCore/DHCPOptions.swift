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
