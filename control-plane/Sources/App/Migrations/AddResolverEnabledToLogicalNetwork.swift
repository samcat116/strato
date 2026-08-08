import Fluent

/// Adds the per-network DNS resolver switch (STR-40, roadmap #769 phase 4):
/// whether the network gives its guests a resolver at its own
/// `NetworkResolverEndpoint` addresses, answered by the host-wide CoreDNS the
/// agent runs in the host namespace (ADR 0008).
///
/// **Defaults to true**, like `metadata_enabled`, and existing networks are
/// carried in on that default rather than opted in one at a time. Two things
/// make that safe. The resolver forwards through the *hypervisor's* egress, so a
/// network whose `dns_servers` list already worked keeps working and a network
/// that could not reach a public resolver at all starts being able to — the bug
/// this phase was filed for. And the control plane withholds the flag entirely
/// unless every agent in the site reports `resolverCapable`, so a site that
/// cannot run CoreDNS is unaffected by the default until it can.
///
/// The column's arrival redefines `dns_servers` for every network that turns it
/// on: it stops being what the guest is told and becomes what the resolver
/// forwards to. No data migration is needed for that — the existing values were
/// already recursive resolvers, which is exactly what an upstream forwarder is.
/// What guests are handed over DHCP does change at their next lease, from that
/// list to the network's link-local resolver address.
struct AddResolverEnabledToLogicalNetwork: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("logical_networks")
            .field("resolver_enabled", .bool, .required, .sql(.default(true)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("logical_networks").deleteField("resolver_enabled").update()
    }
}
