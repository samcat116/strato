import Fluent
import Foundation
import Logging
import SQLKit
import StratoShared

/// Makes the volume↔VM attachment a constrained relationship instead of four
/// independent columns (STR-129).
///
/// `volumes` recorded an attachment in `vm_id`, `device_name`, `boot_order` and
/// `attached_agent_id` with nothing tying them together and no uniqueness
/// anywhere, which produced two reachable failures:
///
/// * Deleting a VM set `vm_id` to NULL through the FK and left everything else
///   as it was, so the volume came to rest `attached` to nothing — undeletable
///   (`canDelete` refuses `.attached`), unattachable (`canAttach` requires
///   `.available`), and outside every sweep.
/// * Two concurrent attaches to one VM both computed the same `disk<N>`, and a
///   later detach of either resolved the disk *by device name* — pulling a live
///   disk out from under the wrong guest.
///
/// This migration repairs both classes of row and then makes them
/// unrepresentable: a unique index per `(vm_id, device_name)` matching the NIC
/// tables, a second on `(vm_id, boot_order)` so the spec's ordering is a total
/// order over real data, a check that an attached row names its device, and a
/// `RESTRICT` foreign key so a VM delete that forgets its volumes fails loudly
/// instead of stranding them (`ResourceFinalizerService.reap` detaches them
/// first, and `VolumeAttachmentService` owns every transition).
///
/// Every step is guarded so a re-run is a no-op.
struct NormalizeVolumeAttachments: AsyncMigration {
    static let deviceNameIndex = "uniq_volumes_vm_id_device_name"
    static let bootOrderIndex = "uniq_volumes_vm_id_boot_order"
    static let deviceNameCheck = "chk_volumes_attached_names_device"
    static let foreignKeyName = "fk_volumes_vm_id_restrict"

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await repairStrandedAttachments(on: sql, logger: database.logger)
        try await repairDeviceNamesAndBootOrders(on: sql, logger: database.logger)

        // NOT VALID + VALIDATE for the same reason `RestrictVMProjectDeletion`
        // splits its constraint: the immediate form holds ACCESS EXCLUSIVE for a
        // full table scan, inside `autoMigrate()`, before this replica serves
        // traffic. The rows were just repaired, so validation cannot fail.
        // Postgres has no `ADD CONSTRAINT IF NOT EXISTS`, so the guard that
        // keeps a re-run a no-op is an explicit look in the catalog.
        if try await !constraintExists(Self.deviceNameCheck, on: sql) {
            try await sql.raw(
                """
                ALTER TABLE volumes ADD CONSTRAINT \(unsafeRaw: Self.deviceNameCheck)
                CHECK (vm_id IS NULL OR device_name IS NOT NULL) NOT VALID
                """
            ).run()
        }
        try await sql.raw(
            "ALTER TABLE volumes VALIDATE CONSTRAINT \(unsafeRaw: Self.deviceNameCheck)"
        ).run()

        // Partial: a detached volume has NULL in both columns, and Postgres
        // treats NULLs as distinct anyway — the predicate just keeps the index
        // to the rows it governs.
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS \(unsafeRaw: Self.deviceNameIndex)
            ON volumes (vm_id, device_name) WHERE vm_id IS NOT NULL
            """
        ).run()
        try await sql.raw(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS \(unsafeRaw: Self.bootOrderIndex)
            ON volumes (vm_id, boot_order) WHERE vm_id IS NOT NULL AND boot_order IS NOT NULL
            """
        ).run()

        try await Self.replaceForeignKey(action: "RESTRICT", on: sql)
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await Self.replaceForeignKey(action: "SET NULL", on: sql)
        try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: Self.bootOrderIndex)").run()
        try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: Self.deviceNameIndex)").run()
        try await sql.raw(
            "ALTER TABLE volumes DROP CONSTRAINT IF EXISTS \(unsafeRaw: Self.deviceNameCheck)"
        ).run()
        // The repaired rows stay repaired: the states they were in are the ones
        // this migration exists to make impossible, and re-creating them would
        // be re-creating the bug.
    }

    // MARK: - Repair

    /// Rows whose VM went away: the FK cleared `vm_id` and nothing cleared the
    /// rest. Restores them to a detached resting state, which is the only thing
    /// the surviving columns could honestly mean.
    private func repairStrandedAttachments(on sql: any SQLDatabase, logger: Logger) async throws {
        let cleared = try await sql.raw(
            """
            UPDATE volumes
            SET device_name = NULL, boot_order = NULL, attached_agent_id = NULL,
                status = CASE WHEN status = \(bind: VolumeStatus.attached.rawValue)
                              THEN \(bind: VolumeStatus.available.rawValue) ELSE status END
            WHERE vm_id IS NULL
              AND (device_name IS NOT NULL OR boot_order IS NOT NULL
                   OR attached_agent_id IS NOT NULL OR status = \(bind: VolumeStatus.attached.rawValue))
            RETURNING id
            """
        ).all()

        if !cleared.isEmpty {
            logger.warning(
                "Repaired volumes stranded by a VM delete",
                metadata: ["count": .stringConvertible(cleared.count)])
        }
    }

    /// One row per volume that is attached to some VM, in the order the names
    /// were most likely handed out.
    private struct AttachedRow: Decodable {
        let id: UUID
        let vmID: UUID
        let deviceName: String?
        let bootOrder: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case vmID = "vm_id"
            case deviceName = "device_name"
            case bootOrder = "boot_order"
        }
    }

    /// Gives every attached volume a legal name unique within its VM, and drops
    /// boot orders that collide.
    ///
    /// The first row of a colliding pair keeps what it has — renaming both would
    /// move a name nobody complained about. `created_at` orders the group so the
    /// keeper is the older attachment, which is the one a guest has been running
    /// against.
    private func repairDeviceNamesAndBootOrders(on sql: any SQLDatabase, logger: Logger) async throws {
        let rows = try await sql.raw(
            """
            SELECT id, vm_id, device_name, boot_order
            FROM volumes
            WHERE vm_id IS NOT NULL
            ORDER BY vm_id, created_at NULLS FIRST, id
            """
        ).all(decoding: AttachedRow.self)

        var takenNames: [UUID: Set<String>] = [:]
        var takenOrders: [UUID: Set<Int>] = [:]
        var renamed = 0
        var reordered = 0

        for row in rows {
            var names = takenNames[row.vmID] ?? []
            var orders = takenOrders[row.vmID] ?? []

            var resolvedName: String? = nil
            if let name = row.deviceName, VolumeDeviceName.isValid(name), !names.contains(name) {
                names.insert(name)
            } else {
                // Lowest free slot, not one past the highest: this is a repair,
                // and a compact numbering is the least surprising thing to find
                // afterwards.
                var index = 0
                while names.contains(VolumeDeviceName.disk(index).rawValue) { index += 1 }
                let replacement = VolumeDeviceName.disk(index).rawValue
                names.insert(replacement)
                resolvedName = replacement
                renamed += 1
            }

            var clearBootOrder = false
            if let bootOrder = row.bootOrder {
                if orders.contains(bootOrder) {
                    clearBootOrder = true
                    reordered += 1
                } else {
                    orders.insert(bootOrder)
                }
            }

            takenNames[row.vmID] = names
            takenOrders[row.vmID] = orders

            guard resolvedName != nil || clearBootOrder else { continue }
            if let resolvedName, clearBootOrder {
                try await sql.raw(
                    """
                    UPDATE volumes SET device_name = \(bind: resolvedName), boot_order = NULL
                    WHERE id = \(bind: row.id)
                    """
                ).run()
            } else if let resolvedName {
                try await sql.raw(
                    "UPDATE volumes SET device_name = \(bind: resolvedName) WHERE id = \(bind: row.id)"
                ).run()
            } else {
                try await sql.raw(
                    "UPDATE volumes SET boot_order = NULL WHERE id = \(bind: row.id)"
                ).run()
            }
        }

        if renamed > 0 || reordered > 0 {
            logger.warning(
                "Repaired duplicate or invalid volume device names and boot orders",
                metadata: [
                    "renamed": .stringConvertible(renamed),
                    "bootOrdersCleared": .stringConvertible(reordered),
                ])
        }
    }

    /// Whether `volumes` already carries a constraint by this name.
    private func constraintExists(_ name: String, on sql: any SQLDatabase) async throws -> Bool {
        let rows = try await sql.raw(
            """
            SELECT 1 FROM pg_constraint con
            JOIN pg_class rel ON rel.oid = con.conrelid
            WHERE rel.relname = 'volumes' AND con.conname = \(bind: name)
            """
        ).all()
        return !rows.isEmpty
    }

    // MARK: - Foreign key

    /// Drop whatever foreign key currently governs `volumes.vm_id` — Fluent's
    /// generated name is not stable enough to hardcode — and install one with
    /// the given delete action. Same `NOT VALID` + `VALIDATE` split, and same
    /// reason, as `RestrictVMProjectDeletion.replaceForeignKey`.
    static func replaceForeignKey(action: String, on sql: any SQLDatabase) async throws {
        let rows = try await sql.raw(
            """
            SELECT con.conname AS name
            FROM pg_constraint con
            JOIN pg_class rel ON rel.oid = con.conrelid
            JOIN pg_attribute att ON att.attrelid = rel.oid AND att.attnum = ANY (con.conkey)
            WHERE rel.relname = 'volumes' AND con.contype = 'f' AND att.attname = 'vm_id'
            """
        ).all()

        for row in rows {
            let name = try row.decode(column: "name", as: String.self)
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            try await sql.raw("ALTER TABLE volumes DROP CONSTRAINT \(unsafeRaw: quoted)").run()
        }

        try await sql.raw(
            """
            ALTER TABLE volumes ADD CONSTRAINT \(unsafeRaw: foreignKeyName)
            FOREIGN KEY (vm_id) REFERENCES vms (id) ON DELETE \(unsafeRaw: action)
            NOT VALID
            """
        ).run()
        try await sql.raw(
            "ALTER TABLE volumes VALIDATE CONSTRAINT \(unsafeRaw: foreignKeyName)"
        ).run()
    }
}
