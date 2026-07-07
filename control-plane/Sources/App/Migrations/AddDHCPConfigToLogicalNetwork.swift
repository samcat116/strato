import Fluent
import SQLKit

/// Adds OVN-native DHCP configuration to logical networks: whether agents should
/// program OVN's DHCP responder for the network, and the DNS resolvers, search
/// domain, and lease time to advertise to guests. The control plane keeps owning
/// IPAM — DHCP is only the delivery mechanism for the IP it already allocates.
///
/// `dhcp_enabled` defaults to true so the seeded "default" network (and any
/// existing operator-created networks) adopt OVN DHCP going forward; operators
/// can flip it back to fall through to the pre-DHCP cloud-init static path.
struct AddDHCPConfigToLogicalNetwork: AsyncMigration {
    func prepare(on database: Database) async throws {
        // One action per update() call: SQLite cannot combine multiple ALTER
        // TABLE actions in a single statement.
        try await database.schema("logical_networks")
            .field("dhcp_enabled", .bool, .required, .sql(.default(true)))
            .update()

        try await database.schema("logical_networks")
            .field("dns_servers", .string)
            .update()

        try await database.schema("logical_networks")
            .field("domain_name", .string)
            .update()

        try await database.schema("logical_networks")
            .field("lease_time", .int)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("logical_networks").deleteField("dhcp_enabled").update()
        try await database.schema("logical_networks").deleteField("dns_servers").update()
        try await database.schema("logical_networks").deleteField("domain_name").update()
        try await database.schema("logical_networks").deleteField("lease_time").update()
    }
}
