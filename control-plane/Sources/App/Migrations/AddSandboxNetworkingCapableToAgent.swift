import Fluent

/// Records whether each agent advertised that it can realize a **sandbox NIC**
/// at its last registration (`AgentRegisterMessage.sandboxNetworkingCapable`,
/// STR-103) — a strictly stronger signal than `sandbox_capable`, because a NIC
/// additionally needs OVN, the jailer barrier, and an installed guest image
/// that configures the interface from the config drive.
///
/// Defaults false, and that default is what makes the upgrade safe rather than
/// merely conservative: sandbox NICs have been allocated control-plane-side
/// since issue #416 while the wire spec withheld them fleet-wide. Without this
/// column reading false until an agent proves otherwise, the first sync after
/// an upgrade would hand every one of those NICs to agents whose guest image
/// predates the config drive's `network` block, failing every sandbox create on
/// those hosts.
struct AddSandboxNetworkingCapableToAgent: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents")
            .field("sandbox_networking_capable", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents")
            .deleteField("sandbox_networking_capable")
            .update()
    }
}
