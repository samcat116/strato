import Fluent
import SQLKit

/// The DNS record model (issue #770): zones, their many-to-many attachment to
/// logical networks, and user-authored records — plus the two columns on
/// existing tables that make derived records placeable (`VM.hostname` and
/// `LogicalNetwork.primaryDNSZone`).
///
/// One feature migration for the whole model (the `CreateSecurityGroup`
/// pattern), because the pieces are only meaningful together: a zone with no
/// attachment resolves for nobody, and a primary-zone pointer with no zone
/// table to point at is not a valid intermediate state.
///
/// FK semantics carry the API's lifecycle rules into the schema:
/// - `dns_records.zone_id` CASCADEs — a zone's records die with it.
/// - `dns_zone_networks` CASCADEs from both sides: deleting either the zone or
///   the network dissolves the attachment, which is a fact about the pair
///   rather than a resource of its own.
/// - `logical_networks.primary_dns_zone_id` is `SET NULL`. Deleting a zone
///   that some network registers into must not orphan the network row; the API
///   refuses the delete while attachments exist, and this is the backstop for
///   the path that gets there anyway (a cascaded project delete).
///
/// `vms.hostname` is backfilled from a slugified `vms.name`, so VMs that
/// predate the column get derived records the moment a zone is attached rather
/// than staying invisible until someone edits each one. Collisions between two
/// VMs whose names slugify alike are possible and deliberately tolerated: the
/// uniqueness rule is per zone, no zone exists yet at migration time, and the
/// API's write-time check is what keeps new ones from being created.
struct CreateDNSZone: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("dns_zones")
            .id()
            .field("name", .string, .required)
            .field("description", .string)
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("created_by_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // Two tenants may legitimately both serve `corp.example.com`
            // internally — the basis for split-horizon later — so the zone
            // name is unique per project, never globally.
            .unique(on: "project_id", "name")
            .create()

        try await database.schema("dns_zone_networks")
            .id()
            .field("zone_id", .uuid, .required, .references("dns_zones", "id", onDelete: .cascade))
            .field(
                "logical_network_id", .uuid, .required,
                .references("logical_networks", "id", onDelete: .cascade)
            )
            .field("created_at", .datetime)
            .unique(on: "zone_id", "logical_network_id")
            .create()

        try await database.schema("dns_records")
            .id()
            .field("zone_id", .uuid, .required, .references("dns_zones", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("type", .string, .required)
            .field("value", .string, .required)
            .field("ttl", .int, .required)
            .field("view", .string, .required)
            .field("created_by_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // An RRset is a *set*: the same name/type may hold several values
            // (round-robin A records), but not the same value twice.
            .unique(on: "zone_id", "name", "type", "value")
            .create()

        try await database.schema("logical_networks")
            .field(
                "primary_dns_zone_id", .uuid,
                .references("dns_zones", "id", onDelete: .setNull)
            )
            .update()

        try await database.schema("vms")
            .field("hostname", .string)
            .update()

        guard let sql = database as? any SQLDatabase else { return }

        // Assembly reads every record of one zone, and every network
        // registering into one zone; neither is served by the composite unique
        // indexes above (both are leftmost on a different column for the
        // network lookup, and the record index is leftmost on zone_id but the
        // planner still benefits from the narrow index on the hot path).
        try await sql.raw("CREATE INDEX ix_dns_records_zone ON dns_records (zone_id)").run()
        try await sql.raw(
            "CREATE INDEX ix_dns_zone_networks_network ON dns_zone_networks (logical_network_id)"
        ).run()
        try await sql.raw(
            "CREATE INDEX ix_logical_networks_primary_dns_zone ON logical_networks (primary_dns_zone_id)"
        ).run()

        // Backfill hostnames — see the type doc. The slug rule matches
        // `DNSName.slugify`: lowercase, every run of non-alphanumerics becomes
        // one hyphen, no leading or trailing hyphen, capped at a 63-octet DNS
        // label, and `vm` when nothing usable survives.
        try await sql.raw(
            """
            UPDATE vms SET hostname = COALESCE(
                NULLIF(
                    TRIM(BOTH '-' FROM LEFT(TRIM(BOTH '-' FROM REGEXP_REPLACE(LOWER(name), '[^a-z0-9]+', '-', 'g')), 63)),
                    ''
                ),
                'vm'
            )
            WHERE hostname IS NULL
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms").deleteField("hostname").update()
        try await database.schema("logical_networks").deleteField("primary_dns_zone_id").update()
        try await database.schema("dns_records").delete()
        try await database.schema("dns_zone_networks").delete()
        try await database.schema("dns_zones").delete()
    }
}
