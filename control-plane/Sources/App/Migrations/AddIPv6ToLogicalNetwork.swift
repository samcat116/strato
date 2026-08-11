import Fluent
import SQLKit
import StratoShared
import Vapor

/// Adds the optional IPv6 subnet/gateway to logical networks (dual-stack
/// support), and seeds a generated RFC 4193 ULA /64 onto the "default"
/// network — but only on fresh installs. Existing deployments are left
/// untouched: retroactively enabling IPv6 on a network whose VMs predate it
/// would leave the network half-configured, so operators opt in per network
/// via the update endpoint instead.
///
/// "Fresh install" is approximated as "no VM and no NIC row has ever
/// existed", the closest honest signal available inside a migration.
/// Overrides: `STRATO_DEFAULT_NETWORK_SUBNET6` supplies an explicit /64;
/// `STRATO_DEFAULT_NETWORK_IPV6=false` keeps the default network v4-only.
struct AddIPv6ToLogicalNetwork: AsyncMigration {
    /// Safety: this mutable Fluent model stays inside one logical operation; child tasks
    /// receive IDs or immutable snapshots and reload their own instance.
    private final class VMRow: Model, @unchecked Sendable {
        static let schema = "vms"

        @ID(key: .id)
        var id: UUID?

        init() {}
    }

    /// Safety: this mutable Fluent model stays inside one logical operation; child tasks
    /// receive IDs or immutable snapshots and reload their own instance.
    private final class InterfaceRow: Model, @unchecked Sendable {
        static let schema = "vm_network_interfaces"

        @ID(key: .id)
        var id: UUID?

        init() {}
    }

    func prepare(on database: Database) async throws {
        try await database.schema("logical_networks")
            .field("subnet6", .string)
            .update()
        try await database.schema("logical_networks")
            .field("gateway6", .string)
            .update()

        if Environment.get("STRATO_DEFAULT_NETWORK_IPV6")?.lowercased() == "false" {
            return
        }

        let subnet6 = try Self.resolveDefaultSubnet6(
            configured: Environment.get("STRATO_DEFAULT_NETWORK_SUBNET6"))

        let gateway6: IPv6Address
        if let configured = Environment.get("STRATO_DEFAULT_NETWORK_GATEWAY6") {
            guard let parsed = IPv6Address(configured), subnet6.contains(parsed),
                parsed != subnet6.networkAddress
            else {
                throw Abort(
                    .internalServerError,
                    reason: "STRATO_DEFAULT_NETWORK_GATEWAY6 is not a host address "
                        + "inside \(subnet6): \(configured)")
            }
            gateway6 = parsed
        } else {
            gateway6 = subnet6.firstHost
        }

        // Fresh installs only: any pre-existing workload means this is an
        // upgrade, and its networks keep their addressing until edited.
        guard try await VMRow.query(on: database).count() == 0,
            try await InterfaceRow.query(on: database).count() == 0
        else { return }

        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "AddIPv6ToLogicalNetwork requires an SQL database")
        }
        // Raw SQL keeps this pinned to today's columns (see CreateLogicalNetwork).
        // No generation bump: on a fresh install no agent has seen the network.
        try await sql.update("logical_networks")
            .set("subnet6", to: SQLBind(subnet6.description))
            .set("gateway6", to: SQLBind(gateway6.description))
            .where("name", .equal, SQLBind(CreateLogicalNetwork.seededDefaultName))
            .run()
    }

    /// Resolves the operator-supplied default without requiring tests to
    /// mutate the process environment while other suites are reading it.
    static func resolveDefaultSubnet6(configured: String?) throws -> IPv6CIDR {
        if let configured {
            // Validate here, where the failure is a clear startup error naming
            // the bad env var (same rationale as CreateLogicalNetwork). Same
            // rules as validateAddressing6: judge the masked network address,
            // reject non-routable prefixes including the unspecified ::/64,
            // and reject the space Strato's own link-local services are drawn
            // from (STR-186) — an operator typing a tidy-looking
            // `fd00:ec2::/64` here is the same vector as typing it at the API.
            guard let parsed = IPv6CIDR(configured), parsed.prefix == 64,
                !parsed.networkAddress.isMulticast, !parsed.networkAddress.isLinkLocal,
                !parsed.networkAddress.isLoopback, !parsed.networkAddress.isUnspecified,
                !NetworkResolverEndpoint.v6SpaceCIDR.overlaps(parsed)
            else {
                throw Abort(
                    .internalServerError,
                    reason: "STRATO_DEFAULT_NETWORK_SUBNET6 is not a usable IPv6 /64 CIDR (it must not "
                        + "overlap \(NetworkResolverEndpoint.v6Space), reserved for instance metadata "
                        + "and the per-network DNS resolvers): \(configured)")
            }
            return parsed
        }
        return IPv6Address.makeULASubnet64()
    }

    func revert(on database: Database) async throws {
        try await database.schema("logical_networks")
            .deleteField("subnet6")
            .update()
        try await database.schema("logical_networks")
            .deleteField("gateway6")
            .update()
    }
}
