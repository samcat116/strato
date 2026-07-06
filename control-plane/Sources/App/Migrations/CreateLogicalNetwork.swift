import Fluent
import Vapor

/// Creates the `logical_networks` table and seeds the "default" network every
/// VM's first NIC attaches to (issue #212: the control plane owns IPAM, per
/// logical network).
///
/// The seeded subnet/gateway default to 192.168.1.0/24 / 192.168.1.1 — the
/// values agents previously hardcoded — so existing deployments keep their
/// addressing. Fresh installs can override via `STRATO_DEFAULT_NETWORK_SUBNET`
/// and `STRATO_DEFAULT_NETWORK_GATEWAY`.
struct CreateLogicalNetwork: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("logical_networks")
            .id()
            .field("name", .string, .required)
            .field("subnet", .string, .required)
            .field("gateway", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "name")
            .create()

        let subnet = Environment.get("STRATO_DEFAULT_NETWORK_SUBNET") ?? "192.168.1.0/24"
        let gateway =
            Environment.get("STRATO_DEFAULT_NETWORK_GATEWAY")
            ?? IPAMService.firstHostAddress(inSubnet: subnet)

        try await LogicalNetwork(
            name: LogicalNetwork.defaultNetworkName,
            subnet: subnet,
            gateway: gateway
        ).save(on: database)
    }

    func revert(on database: Database) async throws {
        try await database.schema("logical_networks").delete()
    }
}
