import Fluent

/// Adds the per-network DNS resolver switch (STR-40, roadmap #769 phase 4):
/// whether the network gives its guests a resolver at `NetworkResolverEndpoint`,
/// answered by a CoreDNS the agent runs in the network's chassis namespace.
///
/// **Defaults to false**, unlike every other network switch here, and the reason
/// is a limitation rather than a preference: the resolver serves a network's
/// zones in full but **cannot yet forward** to upstream servers. Its CoreDNS
/// runs in the network's chassis namespace, whose only egress is an on-link
/// route out the tenant switch with a link-local source — no SNAT rule matches
/// it and no router has a route back to it. Reaching a public resolver needs a
/// path out through the *host*, which is the piece STR-40 did not build.
///
/// So enabling this today trades external resolution for the full internal
/// record vocabulary, and the trade has to be the operator's rather than one an
/// upgrade makes for them. When upstream egress lands this becomes an opt-out
/// like `metadata_enabled`, and the default flips in its own migration.
///
/// The column's arrival redefines `dns_servers` for every network that turns it
/// on: it stops being what the guest is told and becomes what the resolver
/// forwards to. No data migration is needed for that — the existing values were
/// already recursive resolvers, which is exactly what an upstream forwarder is.
struct AddResolverEnabledToLogicalNetwork: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("logical_networks")
            .field("resolver_enabled", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("logical_networks").deleteField("resolver_enabled").update()
    }
}
