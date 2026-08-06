import Fluent

/// Adds the per-network instance metadata switch (STR-49): whether the network
/// publishes the link-local metadata service to its guests, realized by agents
/// as an OVN `localport` on the network's logical switch.
///
/// Defaults to true, like `dhcp_enabled` and `external_access`. The metadata
/// service replaces the boot-time seed ISO rather than supplementing it, so it
/// is the default path and this column is an opt-*out* — an escape hatch for an
/// operator who does not want the extra tenant-reachable surface, not a feature
/// flag that leaves the platform's own provisioning mechanism off until someone
/// finds it.
struct AddMetadataEnabledToLogicalNetwork: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("logical_networks")
            .field("metadata_enabled", .bool, .required, .sql(.default(true)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("logical_networks").deleteField("metadata_enabled").update()
    }
}
