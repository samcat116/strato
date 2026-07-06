import Fluent
import Foundation

/// Adds the SSH public key authorized for a VM's guest login. Nullable: VMs
/// created without a key (or before this migration) simply get no injected key.
struct AddSSHPublicKeyToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vms")
            .field("ssh_public_key", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms")
            .deleteField("ssh_public_key")
            .update()
    }
}
