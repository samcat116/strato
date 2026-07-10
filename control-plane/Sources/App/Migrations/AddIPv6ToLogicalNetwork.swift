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
    private final class VMRow: Model, @unchecked Sendable {
        static let schema = "vms"

        @ID(key: .id)
        var id: UUID?

        init() {}
    }

    private final class InterfaceRow: Model, @unchecked Sendable {
        static let schema = "vm_network_interfaces"

        @ID(key: .id)
        var id: UUID?

        init() {}
    }

    func prepare(on database: Database) async throws {
        // Single action per update() call: SQLite cannot combine multiple
        // ALTER TABLE actions in one statement.
        try await database.schema("logical_networks")
            .field("subnet6", .string)
            .update()
        try await database.schema("logical_networks")
            .field("gateway6", .string)
            .update()

        if Environment.get("STRATO_DEFAULT_NETWORK_IPV6")?.lowercased() == "false" {
            return
        }

        let subnet6: IPv6CIDR
        if let configured = Environment.get("STRATO_DEFAULT_NETWORK_SUBNET6") {
            // Validate here, where the failure is a clear startup error naming
            // the bad env var (same rationale as CreateLogicalNetwork). Same
            // rules as validateAddressing6: judge the masked network address,
            // and reject non-routable prefixes including the unspecified ::/64.
            guard let parsed = IPv6CIDR(configured), parsed.prefix == 64,
                !parsed.networkAddress.isMulticast, !parsed.networkAddress.isLinkLocal,
                !parsed.networkAddress.isLoopback, !parsed.networkAddress.isUnspecified
            else {
                throw Abort(
                    .internalServerError,
                    reason: "STRATO_DEFAULT_NETWORK_SUBNET6 is not a usable IPv6 /64 CIDR: \(configured)")
            }
            subnet6 = parsed
        } else {
            subnet6 = IPv6Address.makeULASubnet64()
        }

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
            .where("name", .equal, SQLBind(LogicalNetwork.defaultNetworkName))
            .run()
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
