import Fluent
import Foundation
import SQLKit
import StratoShared

/// Normalizes NIC addressing out of `vm_network_interfaces` single-address
/// columns into `vm_interface_addresses` (one row per address, keyed by
/// family) so a NIC can carry both an IPv4 and an IPv6 address. Backfills a
/// `family="ipv4"` row from each interface's legacy `ip_address`/`netmask`/
/// `gateway`; the legacy columns stay in place (unwritten) for one release so
/// a binary rollback still boots, and are dropped by a follow-up migration.
struct CreateVMInterfaceAddresses: AsyncMigration {
    /// Point-in-time mapping of `vm_network_interfaces` with only the columns
    /// this migration reads, so later model changes cannot break it (see
    /// `AddGatewayToVMNetworkInterface` for the same pattern).
    private final class InterfaceRow: Model, @unchecked Sendable {
        static let schema = "vm_network_interfaces"

        @ID(key: .id)
        var id: UUID?

        @Field(key: "network")
        var network: String

        @OptionalField(key: "ip_address")
        var ipAddress: String?

        @OptionalField(key: "netmask")
        var netmask: String?

        @OptionalField(key: "gateway")
        var gateway: String?

        init() {}
    }

    /// Point-in-time mapping of `logical_networks`, for the netmask fallback.
    private final class NetworkRow: Model, @unchecked Sendable {
        static let schema = "logical_networks"

        @ID(key: .id)
        var id: UUID?

        @Field(key: "name")
        var name: String

        @Field(key: "subnet")
        var subnet: String

        init() {}
    }

    private final class AddressRow: Model, @unchecked Sendable {
        static let schema = "vm_interface_addresses"

        @ID(key: .id)
        var id: UUID?

        @Field(key: "interface_id")
        var interfaceID: UUID

        @Field(key: "network")
        var network: String

        @Field(key: "family")
        var family: String

        @Field(key: "address")
        var address: String

        @Field(key: "prefix_length")
        var prefixLength: Int

        @OptionalField(key: "gateway")
        var gateway: String?

        @Timestamp(key: "created_at", on: .create)
        var createdAt: Date?

        @Timestamp(key: "updated_at", on: .update)
        var updatedAt: Date?

        init() {}
    }

    func prepare(on database: Database) async throws {
        try await database.schema("vm_interface_addresses")
            .id()
            .field(
                "interface_id", .uuid, .required,
                .references("vm_network_interfaces", "id", onDelete: .cascade)
            )
            .field("network", .string, .required)
            .field("family", .string, .required)
            .field("address", .string, .required)
            .field("prefix_length", .int, .required)
            .field("gateway", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        if let sql = database as? SQLDatabase {
            // The IPAM uniqueness backstop, replacing the role of
            // idx_vm_network_interfaces_network_ip (which stays until the
            // legacy columns are dropped). No unique(interface_id, family):
            // one-address-per-family is enforced in code so the schema
            // permits multiple addresses per family later.
            try await sql.raw(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_vm_interface_addresses_network_address "
                    + "ON vm_interface_addresses (network, address)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_vm_interface_addresses_interface "
                    + "ON vm_interface_addresses (interface_id)"
            ).run()
        }

        // Backfill: one ipv4 row per legacy-addressed interface. Prefix from
        // the interface's netmask, else the owning network's subnet, else /24
        // (loudly) — a wrong-but-plausible prefix beats dropping the address.
        let subnetPrefixes = try await Dictionary(
            NetworkRow.query(on: database).all().map { network -> (String, Int?) in
                (network.name, network.subnet.split(separator: "/").last.flatMap { Int($0) })
            },
            uniquingKeysWith: { first, _ in first }
        )

        let interfaces = try await InterfaceRow.query(on: database)
            .filter(\.$ipAddress != nil)
            .all()
        var defaulted = 0
        for interface in interfaces {
            guard let ipAddress = interface.ipAddress, let interfaceID = interface.id else { continue }
            let prefix: Int
            if let fromMask = interface.netmask.flatMap({ IPv4Address($0)?.prefixLength }) {
                prefix = fromMask
            } else if let fromSubnet = subnetPrefixes[interface.network] ?? nil {
                prefix = fromSubnet
            } else {
                prefix = 24
                defaulted += 1
            }

            let row = AddressRow()
            row.interfaceID = interfaceID
            row.network = interface.network
            row.family = IPFamily.ipv4.rawValue
            row.address = ipAddress
            row.prefixLength = prefix
            row.gateway = interface.gateway
            try await row.save(on: database)
        }
        if defaulted > 0 {
            database.logger.warning(
                "Backfilled NIC addresses with an assumed /24 prefix (no parsable netmask or subnet)",
                metadata: ["count": .stringConvertible(defaulted)])
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_interface_addresses_network_address").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_vm_interface_addresses_interface").run()
        }
        try await database.schema("vm_interface_addresses").delete()
    }
}
