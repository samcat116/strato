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

        // Validate operator-supplied values here, where the failure is a clear
        // startup error naming the bad env var — not later, when IPAM would
        // either refuse every VM create or (for a malformed gateway) hand the
        // gateway's address out to a VM.
        let subnet = Environment.get("STRATO_DEFAULT_NETWORK_SUBNET") ?? "192.168.1.0/24"
        guard let (_, prefix) = IPAMService.parseCIDR(subnet),
            IPAMService.allocatablePrefixRange.contains(prefix)
        else {
            throw Abort(
                .internalServerError,
                reason: "STRATO_DEFAULT_NETWORK_SUBNET is not a usable IPv4 CIDR "
                    + "(/\(IPAMService.allocatablePrefixRange.lowerBound)–"
                    + "/\(IPAMService.allocatablePrefixRange.upperBound)): \(subnet)")
        }

        let gateway: String?
        if let configured = Environment.get("STRATO_DEFAULT_NETWORK_GATEWAY") {
            guard IPAMService.parseIPv4(configured) != nil else {
                throw Abort(
                    .internalServerError,
                    reason: "STRATO_DEFAULT_NETWORK_GATEWAY is not an IPv4 address: \(configured)")
            }
            gateway = configured
        } else {
            gateway = IPAMService.firstHostAddress(inSubnet: subnet)
        }

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
