import Fluent

/// Records whether each agent advertised a usable CoreDNS at its last
/// registration (`AgentRegisterMessage.resolverCapable`, STR-40).
///
/// Read site-wide rather than per agent, which is what makes the default matter
/// here. A network's resolver is advertised to guests through one DHCP row
/// authored by the site's topology authority, but answered by a process on each
/// chassis — so the control plane withholds the resolver from a network unless
/// *every* agent in the site is capable. Defaulting false means an upgraded
/// control plane in front of a fleet that has not restarted yet keeps handing
/// guests the configured resolver list, exactly as before, until each agent
/// re-registers and proves otherwise.
struct AddResolverCapableToAgent: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents")
            .field("resolver_capable", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents")
            .deleteField("resolver_capable")
            .update()
    }
}
