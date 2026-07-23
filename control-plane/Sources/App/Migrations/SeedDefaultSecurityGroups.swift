import Fluent
import Foundation
import SQLKit

/// Backfills the mandatory per-project `default` security group.
///
/// Security groups are AWS-shaped: every NIC must belong to at least one
/// group, so pre-existing projects and NICs need rows before the API can
/// enforce the invariant. Every existing project gets a `default` group with
/// AWS default-group semantics — allow all ingress from the group itself,
/// allow all egress — and every existing NIC joins its project's group.
///
/// Projects that already have workloads (≥1 VM NIC) additionally get a
/// **deletable allow-all-ingress rule**: enforcement only begins when agents
/// upgrade to the security-group protocol, and without this rule that upgrade
/// would silently cut inbound traffic to every pre-existing VM. Deleting the
/// rule is how an operator opts a project into real ingress filtering.
/// Workload-less projects skip it and get the pure AWS posture.
///
/// Raw SQL with column-snapshot rows, never live models (the
/// `MigrateVMDisksToVolumes` lesson): future model changes must not alter
/// what this migration writes.
struct SeedDefaultSecurityGroups: AsyncMigration {
    static let migrationRuleDescription =
        "Migration: preserves pre-security-group connectivity. Delete to enforce ingress filtering."

    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQLDatabase
        }

        let projects = try await sql.select()
            .column("id")
            .from("projects")
            .all(decoding: IDRow.self)

        for project in projects {
            // Idempotence across a revert/re-run: skip projects that already
            // have a default group (the partial unique index would refuse the
            // insert anyway; skipping keeps the run clean).
            let existing = try await sql.select()
                .column("id")
                .from("security_groups")
                .where("project_id", .equal, SQLBind(project.id))
                .where("is_default", .equal, SQLBind(true))
                .first(decoding: IDRow.self)
            if existing != nil { continue }

            let nics = try await sql.select()
                .column(SQLColumn("id", table: "vm_network_interfaces"))
                .from("vm_network_interfaces")
                .join(
                    "vms", method: SQLJoinMethod.inner,
                    on: SQLColumn("vm_id", table: "vm_network_interfaces"),
                    .equal, SQLColumn("id", table: "vms")
                )
                .where(SQLColumn("project_id", table: "vms"), .equal, SQLBind(project.id))
                .all(decoding: IDRow.self)

            let groupID = UUID()
            let now = Date()
            try await sql.insert(into: "security_groups")
                .columns("id", "project_id", "name", "is_default", "generation", "created_at", "updated_at")
                .values(
                    SQLBind(groupID), SQLBind(project.id), SQLBind("default"),
                    SQLBind(true), SQLBind(0), SQLBind(now), SQLBind(now)
                )
                .run()

            // AWS default-group semantics: members accept everything from
            // other members, and all egress is open. One rule per family.
            var rules: [(direction: String, ethertype: String, remoteGroup: UUID?, description: String?)] = [
                ("ingress", "ipv4", groupID, nil),
                ("ingress", "ipv6", groupID, nil),
                ("egress", "ipv4", nil, nil),
                ("egress", "ipv6", nil, nil),
            ]
            if !nics.isEmpty {
                rules.append(("ingress", "ipv4", nil, Self.migrationRuleDescription))
                rules.append(("ingress", "ipv6", nil, Self.migrationRuleDescription))
            }
            for rule in rules {
                try await sql.insert(into: "security_group_rules")
                    .columns(
                        "id", "security_group_id", "direction", "ethertype",
                        "remote_group_id", "description", "created_at"
                    )
                    .values(
                        SQLBind(UUID()), SQLBind(groupID), SQLBind(rule.direction),
                        SQLBind(rule.ethertype), SQLBind(rule.remoteGroup),
                        SQLBind(rule.description), SQLBind(now)
                    )
                    .run()
            }

            for nic in nics {
                try await sql.insert(into: "vm_interface_security_groups")
                    .columns("id", "interface_id", "security_group_id", "created_at")
                    .values(SQLBind(UUID()), SQLBind(nic.id), SQLBind(groupID), SQLBind(now))
                    .run()
            }
        }
    }

    /// Deletes only what this migration creates: default groups (their rules
    /// and memberships cascade or are removed first to satisfy RESTRICT FKs).
    func revert(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQLDatabase
        }
        try await sql.raw(
            """
            DELETE FROM vm_interface_security_groups
            WHERE security_group_id IN (SELECT id FROM security_groups WHERE is_default)
            """
        ).run()
        try await sql.raw("DELETE FROM security_groups WHERE is_default").run()
    }

    private struct IDRow: Decodable {
        let id: UUID
    }

    enum MigrationError: Error {
        case requiresSQLDatabase
    }
}
