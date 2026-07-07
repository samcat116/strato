import Fluent
import SQLKit

/// Records on each registration token whether creating it also provisioned the
/// node in SPIRE (join token + workload entry). Revocation uses this to decide
/// exactly which token owns a SPIRE grant instead of inferring from the
/// current process configuration — a successor token minted while the SPIRE
/// registration API was unconfigured carries no grant and must not absorb
/// ownership of an older token's.
struct AddSPIREProvisionedToAgentRegistrationToken: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agent_registration_tokens")
            .field("spire_provisioned", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agent_registration_tokens")
            .deleteField("spire_provisioned")
            .update()
    }
}
