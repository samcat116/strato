import Fluent
import SQLKit

/// Optional, one-per-network stateless ACLs and their ordered rules (STR-33).
/// Existing logical networks intentionally receive no ACL row.
struct CreateNetworkACLs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(NetworkACL.schema)
            .id()
            .field(
                "logical_network_id", .uuid, .required,
                .references(LogicalNetwork.schema, "id", onDelete: .cascade)
            )
            .field("generation", .int64, .required, .sql(.default(1)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "logical_network_id", name: "uq_network_acls_logical_network")
            .create()

        try await database.schema(NetworkACLRule.schema)
            .id()
            .field(
                "network_acl_id", .uuid, .required,
                .references(NetworkACL.schema, "id", onDelete: .cascade)
            )
            .field("rule_number", .int, .required)
            .field("direction", .string, .required)
            .field("ethertype", .string, .required)
            .field("action", .string, .required)
            .field("protocol", .string)
            .field("port_range_min", .int)
            .field("port_range_max", .int)
            .field("remote_cidr", .string, .required)
            .field("description", .string)
            .field("created_at", .datetime)
            .unique(
                on: "network_acl_id", "direction", "rule_number",
                name: "uq_network_acl_rules_order"
            )
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            """
            ALTER TABLE network_acls
            ADD CONSTRAINT ck_network_acls_generation CHECK (generation >= 1)
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE network_acl_rules
            ADD CONSTRAINT ck_network_acl_rules_rule_number
            CHECK (rule_number BETWEEN 1 AND 32766)
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE network_acl_rules
            ADD CONSTRAINT ck_network_acl_rules_direction
            CHECK (direction IN ('ingress', 'egress'))
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE network_acl_rules
            ADD CONSTRAINT ck_network_acl_rules_ethertype
            CHECK (ethertype IN ('ipv4', 'ipv6'))
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE network_acl_rules
            ADD CONSTRAINT ck_network_acl_rules_action
            CHECK (action IN ('allow', 'deny'))
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE network_acl_rules
            ADD CONSTRAINT ck_network_acl_rules_protocol
            CHECK (protocol IS NULL OR protocol IN ('tcp', 'udp', 'icmp'))
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE network_acl_rules
            ADD CONSTRAINT ck_network_acl_rules_description_length
            CHECK (char_length(description) <= 4096)
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE network_acl_rules
            ADD CONSTRAINT ck_network_acl_rules_ports
            CHECK (
                (protocol IS NULL AND port_range_min IS NULL AND port_range_max IS NULL)
                OR (
                    protocol IN ('tcp', 'udp')
                    AND (
                        (port_range_min IS NULL AND port_range_max IS NULL)
                        OR (
                            port_range_min IS NOT NULL
                            AND port_range_max IS NOT NULL
                            AND port_range_min BETWEEN 0 AND 65535
                            AND port_range_max BETWEEN port_range_min AND 65535
                        )
                    )
                )
                OR (
                    protocol = 'icmp'
                    AND (
                        (port_range_min IS NULL AND port_range_max IS NULL)
                        OR (
                            port_range_min IS NOT NULL
                            AND port_range_min BETWEEN 0 AND 255
                            AND (port_range_max IS NULL OR port_range_max BETWEEN 0 AND 255)
                        )
                    )
                )
            )
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(NetworkACLRule.schema).delete()
        try await database.schema(NetworkACL.schema).delete()
    }
}
