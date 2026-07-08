import Foundation

/// The host's outbound network attachment, used as the SNAT target and provider
/// bridge uplink for OVN L3 egress (issue #342). Auto-detected from the kernel's
/// default route so a single-node deployment needs no operator uplink config.
public struct HostUplink: Equatable, Sendable {
    /// The source IP the kernel uses to reach off-host traffic — the SNAT
    /// external IP and the external router port's address.
    public let ipAddress: String
    /// The interface that carries the default route (the provider uplink NIC).
    public let interface: String
    /// The prefix length of the uplink subnet, for the external router port's
    /// `networks` CIDR.
    public let prefixLength: Int
    /// The default-route next hop (uplink gateway), or nil when the uplink is on
    /// a directly-connected subnet with no gateway. The logical router's default
    /// static route points here so off-subnet traffic can egress under SNAT.
    public let gateway: String?

    public init(ipAddress: String, interface: String, prefixLength: Int, gateway: String? = nil) {
        self.ipAddress = ipAddress
        self.interface = interface
        self.prefixLength = prefixLength
        self.gateway = gateway
    }

    /// The external router port address, `ip/prefix`.
    public var cidr: String { "\(ipAddress)/\(prefixLength)" }
}

/// Pure parsing for host-uplink auto-detection. The Linux network service runs
/// the `ip` commands; keeping the JSON parsing here makes it unit-testable on
/// any platform, mirroring `OVNChassisBootstrap`.
public enum HostUplinkDetection {

    /// Extracts the preferred source IP, egress device, and next-hop gateway from
    /// `ip -j route get <probe>` output, e.g.
    /// `[{"dst":"1.1.1.1","gateway":"192.168.1.1","dev":"eth0","prefsrc":"192.168.1.10",...}]`.
    /// `gateway` is nil for a directly-connected uplink (no next hop).
    public static func parseRoute(_ json: String) -> (ip: String, device: String, gateway: String?)? {
        guard let data = json.data(using: .utf8),
            let routes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let route = routes.first,
            let source = route["prefsrc"] as? String, !source.isEmpty,
            let device = route["dev"] as? String, !device.isEmpty
        else {
            return nil
        }
        let gateway = (route["gateway"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (source, device, gateway)
    }

    /// Finds the prefix length assigned to `ip` in `ip -j addr show dev <dev>`
    /// output, e.g. `[{"addr_info":[{"family":"inet","local":"192.168.1.10","prefixlen":24}]}]`.
    public static func parsePrefixLength(_ json: String, forIP ip: String) -> Int? {
        guard let data = json.data(using: .utf8),
            let interfaces = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return nil
        }
        for interface in interfaces {
            guard let addrInfo = interface["addr_info"] as? [[String: Any]] else { continue }
            for addr in addrInfo {
                if (addr["family"] as? String) == "inet",
                    (addr["local"] as? String) == ip,
                    let prefix = addr["prefixlen"] as? Int
                {
                    return prefix
                }
            }
        }
        return nil
    }
}

/// Pure merge logic for the local OVS `ovn-bridge-mappings` external-id, which
/// maps OVN provider networks (physnets) to OVS bridges as a comma-separated
/// `physnet:bridge` list. The agent adds its provider mapping idempotently
/// without clobbering mappings an operator (or another feature) already set.
public enum OVNBridgeMappings {
    /// Returns the new `ovn-bridge-mappings` value with `physnet:bridge` present,
    /// or nil when it is already mapped to `bridge` (no change needed). If the
    /// physnet maps to a *different* bridge, that entry is replaced.
    public static func merged(existing: String?, physnet: String, bridge: String) -> String? {
        var pairs: [(physnet: String, bridge: String)] = []
        if let existing {
            for entry in existing.split(separator: ",") {
                let parts = entry.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count == 2, !parts[0].isEmpty else { continue }
                pairs.append((parts[0], parts[1]))
            }
        }

        if let index = pairs.firstIndex(where: { $0.physnet == physnet }) {
            if pairs[index].bridge == bridge { return nil }
            pairs[index].bridge = bridge
        } else {
            pairs.append((physnet, bridge))
        }
        return pairs.map { "\($0.physnet):\($0.bridge)" }.joined(separator: ",")
    }
}
