import Fluent
import SQLKit
import StratoShared
import Vapor

/// The volume↔VM attachment, as one relationship rather than four columns
/// (STR-129).
///
/// `volumes` records an attachment across `vm_id`, `device_name`, `boot_order`
/// and `attached_agent_id`, plus a `status` enum. Nothing tied them together,
/// so every call site was free to move a subset and leave a row describing a
/// state that cannot exist — most visibly a VM delete, where the FK set `vm_id`
/// to NULL and left `status = attached`, a volume that could then be neither
/// deleted (`canDelete` refuses `.attached`) nor re-attached (`canAttach`
/// requires `.available`) nor recovered by any sweep.
///
/// Every transition now goes through here: claim and release each move all four
/// columns together, and claim runs under the same per-subject advisory lock
/// idiom `IPAMService.lockAllocations` uses, so the read-allocate-write cycle
/// behind an auto-generated device name serializes across replicas. The
/// `(vm_id, device_name)` unique index added by `NormalizeVolumeAttachments` is
/// the backstop, not the only defense.
enum VolumeAttachmentService {

    // MARK: - Serialization

    /// Serializes attachment writes for one VM. Transaction-scoped, so it is
    /// released by the commit or rollback and there is nothing to leak; a
    /// non-Postgres database (none in production) is a no-op, exactly as IPAM
    /// treats it.
    ///
    /// Keyed on the VM rather than the volume: what races is the *set* of names
    /// on one VM, which two different volumes contend for.
    static func lock(vmID: UUID, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase, sql.dialect.name == "postgresql" else { return }
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtext(\(bind: lockKey(vmID: vmID))))").run()
    }

    static func lockKey(vmID: UUID) -> String {
        "volume-attach:\(vmID.uuidString)"
    }

    // MARK: - Claim

    /// Binds `volume` to `vm` under `deviceName`, generating one when the caller
    /// named none, and leaves the row in `.attaching` for the agent round trip
    /// to confirm.
    ///
    /// Must be called inside a transaction that already holds `lock(vmID:)`:
    /// both the generated name and the duplicate checks read the VM's current
    /// attachments, and neither is meaningful if a concurrent attach can insert
    /// between the read and the write.
    ///
    /// - Returns: the device name the volume was claimed under.
    @discardableResult
    static func claim(
        _ volume: Volume,
        to vm: VM,
        deviceName requested: VolumeDeviceName?,
        bootOrder: Int?,
        on db: any Database
    ) async throws -> VolumeDeviceName {
        let vmID = try vm.requireID()

        // Every volume already pointing at this VM, whatever its status: a row
        // mid-`.attaching` has claimed its name just as firmly as an attached
        // one, and the unique index does not care about status either.
        let siblings = try await Volume.query(on: db)
            .filter(\.$vm.$id == vmID)
            .all()
            .filter { $0.id != volume.id }

        let deviceName =
            try requested
            ?? VolumeNaming.nextDeviceName(
                existingDeviceNames: siblings.map(\.deviceName))

        guard !siblings.contains(where: { $0.deviceName == deviceName.rawValue }) else {
            throw Abort(
                .conflict,
                reason: "Device name '\(deviceName)' is already in use on this VM")
        }

        if let bootOrder {
            guard bootOrder >= 0 else {
                throw Abort(.badRequest, reason: "'bootOrder' must not be negative")
            }
            guard !siblings.contains(where: { $0.bootOrder == bootOrder }) else {
                // Two volumes at the same priority make the boot order of both
                // arbitrary — the spec's sort would have to break the tie on
                // something the caller never chose.
                throw Abort(
                    .conflict,
                    reason: "Boot order \(bootOrder) is already in use on this VM")
            }
        }

        volume.status = .attaching
        volume.$vm.id = vmID
        volume.deviceName = deviceName.rawValue
        volume.bootOrder = bootOrder
        // The volume's replica placement is set at provisioning and must not be
        // overwritten here; this records where the *attachment* runs.
        volume.attachedAgentId = vm.hypervisorId
        do {
            try await volume.save(on: db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // The unique index caught what the checks above could not: a
            // concurrent attach on a replica that could not take the advisory
            // lock (a non-Postgres database, or a lock this transaction never
            // acquired). Reported as the same conflict, not a 500.
            throw Abort(
                .conflict,
                reason:
                    "Device name '\(deviceName)' or boot order is already in use on this VM "
                    + "(claimed by a concurrent attach)")
        }
        return deviceName
    }

    // MARK: - Release

    /// Returns `volume` to a detached resting state, in memory. All four
    /// attachment columns and the status move together — the whole point of
    /// routing every caller through one function.
    static func clearAttachment(_ volume: Volume) {
        volume.$vm.id = nil
        volume.deviceName = nil
        volume.bootOrder = nil
        volume.attachedAgentId = nil
        volume.status = .available
    }

    /// The same, for a row whose VM is already gone: the status moves only if it
    /// still claims to be `.attached`.
    ///
    /// The sweep that calls this is repairing an *attachment*, not an operation.
    /// A row caught mid-`.deleting` when its VM went away is still being
    /// deleted, and answering `.available` would report a delete as undone.
    static func clearStrandedAttachment(_ volume: Volume) {
        let status = volume.status
        clearAttachment(volume)
        if status != .attached {
            volume.status = status
        }
    }

    /// Detaches and persists a single volume.
    static func release(_ volume: Volume, on db: any Database) async throws {
        clearAttachment(volume)
        try await volume.save(on: db)
    }

    /// Detaches every volume attached to `vmID`, whatever state each is in.
    ///
    /// Called from the VM reap inside the delete transaction: the guest is
    /// going away, so there is no hot-unplug to perform and nothing to wait
    /// for — the volume's data is intact on the agent and the row becomes
    /// reusable. Unconditional on status on purpose: `volumes.vm_id` is
    /// `ON DELETE RESTRICT`, so a row this skipped would fail the VM's delete,
    /// and "a dead agent must not make its VM undeletable" outranks preserving
    /// an in-flight volume operation that has nothing left to converge on.
    ///
    /// - Returns: the volumes it detached, for the caller's log.
    @discardableResult
    static func releaseAll(fromVM vmID: UUID, on db: any Database) async throws -> [UUID] {
        let attached = try await Volume.query(on: db)
            .filter(\.$vm.$id == vmID)
            .all()

        for volume in attached {
            clearAttachment(volume)
            try await volume.save(on: db)
        }
        return attached.compactMap(\.id)
    }
}
