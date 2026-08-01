import Fluent
import Foundation

/// Graphics console (issue #566): whether a VM boots with a display device and
/// a VNC server, so its framebuffer can be relayed to the browser.
///
/// `vms.graphics_console` defaults false, which is exactly today's behavior —
/// every existing VM is headless and its QEMU argument vector is unchanged.
///
/// A Bool rather than a mode enum, even though the wire carries a
/// `GraphicsMode`: the persisted-enum machinery (`EnforcePersistedEnumValues`)
/// requires a follow-up migration and a matching registry entry for every case
/// ever added, and there is nothing to gain from paying that here. The wire
/// stays an enum so a second protocol (SPICE) can arrive without reshaping the
/// spec; the column only records whether the operator asked for a display,
/// which is the part that has to survive in the database.
struct AddGraphicsConsoleToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vms")
            .field("graphics_console", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms")
            .deleteField("graphics_console")
            .update()
    }
}
