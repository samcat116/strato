import Foundation

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
