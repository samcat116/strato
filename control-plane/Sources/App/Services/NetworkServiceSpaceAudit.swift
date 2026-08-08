import Fluent
import Logging
import StratoShared

/// Surfaces networks written before the service-space reservation existed.
///
/// Renumbering a tenant network is not safe to automate: its gateway, NICs and
/// guest configuration all have to move together. The write path prevents new
/// collisions; this startup audit makes the legacy rows actionable instead of
/// leaving their metadata/resolver ACL exposure silent.
enum NetworkServiceSpaceAudit {
    static func collidingNetworks(on database: Database) async throws -> [LogicalNetwork] {
        try await LogicalNetwork.query(on: database).all().filter { network in
            guard let subnet6 = network.subnet6, let cidr = IPv6CIDR(subnet6) else { return false }
            return NetworkResolverEndpoint.v6SpaceCIDR.overlaps(cidr)
        }
    }

    static func warnAboutCollidingNetworks(on database: Database, logger: Logger) async throws {
        for network in try await collidingNetworks(on: database) {
            logger.warning(
                "Logical network IPv6 subnet overlaps Strato's reserved service space; renumber the network",
                metadata: [
                    "networkId": .string(network.id?.uuidString ?? "unknown"),
                    "networkName": .string(network.name),
                    "subnet6": .string(network.subnet6 ?? "unknown"),
                    "reservedSpace": .string(NetworkResolverEndpoint.v6Space),
                    "impact": .string(
                        "metadata and resolver ACL carve-outs can target tenant addresses; IPv6 edits are blocked"),
                ])
        }
    }
}
