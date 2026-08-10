import Fluent
import SQLKit

/// Removes the duplicate string capability bag from agent records (STR-222).
///
/// Hypervisor availability and features, networking, sandbox runtime and NIC
/// support, vTPM, host metadata, and DNS resolver support are all persisted in
/// typed fields populated by the same registration probes. Keeping their old
/// string aliases made it possible for placement and admission to disagree
/// with those reports.
struct DropLegacyAgentCapabilities: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("agents")
            .deleteField("capabilities")
            .update()
    }

    func revert(on database: any Database) async throws {
        let emptyArrayDefault =
            (database as? SQLDatabase)?.dialect.name == "postgresql"
            ? "DEFAULT '{}'"
            : "DEFAULT '[]'"
        try await database.schema("agents")
            .field("capabilities", .array(of: .string), .required, .custom(emptyArrayDefault))
            .update()
    }
}
