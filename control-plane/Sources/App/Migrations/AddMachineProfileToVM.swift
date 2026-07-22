import Fluent
import Foundation

/// Windows guest support (issue #565): the per-VM machine profile, plus the
/// host capability the scheduler gates it on.
///
/// * `vms.secure_boot` / `vms.tpm_enabled` — the VM's requested machine
///   features. Both default false, which is exactly today's behavior, so
///   existing VMs are unaffected.
/// * `agents.tpm_capable` — whether the agent advertised a usable `swtpm` at
///   its last registration. Defaults false for the same reason
///   `sandbox_capable` does: a row that predates the column has proven
///   nothing, and must stay ineligible until the agent re-registers.
struct AddMachineProfileToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        // One action per update() call, matching the sibling migrations.
        try await database.schema("vms")
            .field("secure_boot", .bool, .required, .sql(.default(false)))
            .update()
        try await database.schema("vms")
            .field("tpm_enabled", .bool, .required, .sql(.default(false)))
            .update()
        try await database.schema("agents")
            .field("tpm_capable", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms")
            .deleteField("secure_boot")
            .update()
        try await database.schema("vms")
            .deleteField("tpm_enabled")
            .update()
        try await database.schema("agents")
            .deleteField("tpm_capable")
            .update()
    }
}
