import Fluent

/// Records whether each agent advertised the sandbox runtime at its last
/// registration (`AgentRegisterMessage.sandboxCapable`, issue #415). The
/// scheduler keys sandbox placement on this explicit signal — never on the
/// wire protocol version alone, which proves an agent understands the sandbox
/// fields but not that it runs the runtime. Defaults false: rows that predate
/// the column stay ineligible until the agent re-registers and proves
/// otherwise.
struct AddSandboxCapableToAgent: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents")
            .field("sandbox_capable", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents")
            .deleteField("sandbox_capable")
            .update()
    }
}
