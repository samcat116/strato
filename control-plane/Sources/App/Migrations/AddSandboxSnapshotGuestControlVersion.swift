import Fluent

/// Records the protocol spoken by the guest init frozen into a checkpoint.
/// Agent wire version is not sufficient after an upgrade: the live agent may
/// own a microVM whose memory still contains an older guest binary.
struct AddSandboxSnapshotGuestControlVersion: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(SandboxSnapshot.schema)
            .field("guest_control_protocol_version", .int)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(SandboxSnapshot.schema)
            .deleteField("guest_control_protocol_version")
            .update()
    }
}
