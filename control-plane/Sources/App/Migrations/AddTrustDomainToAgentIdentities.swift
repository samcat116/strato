import Fluent
import SQLKit

/// Scopes agent identity by trust domain (issue #613).
///
/// Both `agents.name` and `agent_enrollments.agent_name` were globally unique,
/// and the in-process connection maps keyed agents by that bare name. With one
/// trust domain that is merely redundant; with a trust domain per organization
/// it is a correctness bug — two organizations enrolling `agent-1` would collide
/// on the enrollment insert, and (worse) their sockets would share a map entry,
/// so one org's agent could be handed the other's desired state.
///
/// The identity key becomes the full SPIFFE ID, whose two components are the
/// trust domain and the name. Existing rows all belong to the platform trust
/// domain, which is what they are backfilled with — read from the same
/// `SPIRE_TRUST_DOMAIN` environment variable the running control plane resolves
/// its own domain from, so a deployment that renamed it stays consistent.
struct AddTrustDomainToAgentIdentities: AsyncMigration {
    struct UnsupportedDatabase: Error {}

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        let platformTrustDomain = PlatformTrustDomain.current
        for table in ["agents", "agent_enrollments"] {
            try await sql.raw("ALTER TABLE \(ident: table) ADD COLUMN trust_domain text").run()
            try await sql.raw("UPDATE \(ident: table) SET trust_domain = \(bind: platformTrustDomain)").run()
            try await sql.raw("ALTER TABLE \(ident: table) ALTER COLUMN trust_domain SET NOT NULL").run()
        }

        try await database.schema("agents")
            .deleteUnique(on: "name")
            .unique(on: "trust_domain", "name")
            .update()

        try await database.schema("agent_enrollments")
            .deleteUnique(on: "agent_name")
            .unique(on: "trust_domain", "agent_name")
            .update()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        try await database.schema("agents")
            .deleteUnique(on: "trust_domain", "name")
            .unique(on: "name")
            .update()

        try await database.schema("agent_enrollments")
            .deleteUnique(on: "trust_domain", "agent_name")
            .unique(on: "agent_name")
            .update()

        for table in ["agents", "agent_enrollments"] {
            try await sql.raw("ALTER TABLE \(ident: table) DROP COLUMN trust_domain").run()
        }
    }
}
