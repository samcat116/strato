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
/// `(vm_id, device_name)` unique index is the backstop, not the only defense.
enum VolumeAttachmentService {
    struct Claim: Sendable {
        let volume: Volume
        let deviceName: VolumeDeviceName
    }

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

    /// Writes `volume`'s desired attachment to `vm` under `deviceName`,
    /// generating one when the caller named none. This mutates attachment
    /// intent only; the owning `ResourceMutation.accept` advances generation.
    ///
    /// Takes the lock itself, so no caller can forget it: both the generated
    /// name and the duplicate checks read the VM's current attachments, and
    /// neither is meaningful if a concurrent attach can write between the read
    /// and this one. Call inside a transaction — `ResourceMutation.accept`'s,
    /// in the attach path — since the lock is transaction-scoped.
    ///
    /// Nothing here touches `status`: since STR-148 that column is what the
    /// agent last observed, and the control plane writing it would be inventing
    /// an observation.
    ///
    /// - Returns: the device name the volume was claimed under.
    @discardableResult
    static func claim(
        _ volume: Volume,
        to vm: VM,
        deviceName requested: VolumeDeviceName?,
        bootOrder: Int?,
        readonly: Bool,
        on db: any Database
    ) async throws -> Claim {
        let vmID = try vm.requireID()
        try await lock(vmID: vmID, on: db)

        // Asked again, and this time of the row as it is: the caller's
        // `canAttach` was answered against the snapshot the request loaded,
        // while `ResourceMutation.accept`'s `lockAndRefresh` has since taken
        // the row lock and adopted the committed attachment. Two attaches of
        // one volume to two different VMs serialize on that row lock, and this
        // is what makes the second of them a `409` rather than a silent move.
        guard volume.canAttach else {
            throw Abort(.conflict, reason: "Volume is already attached to a VM. Detach it first.")
        }

        // Every volume already pointing at this VM: a desired attachment claims
        // its name whether or not the agent has realized it yet, and the unique
        // index does not care either.
        let siblings = try await LegacyVolumeStore.volumes(
            attachment: .attachedTo(vmID), on: db)
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

        let claimed = volume.replacing(
            attachedAgentId: .some(vm.hypervisorId), vmID: .some(vmID),
            deviceName: .some(deviceName.rawValue), bootOrder: .some(bootOrder),
            readonly: readonly)
        // The volume's replica placement is set at provisioning and must not be
        // overwritten here; this records where the *attachment* runs.
        do {
            try await claimed.save(on: db)
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
        return Claim(volume: claimed, deviceName: deviceName)
    }

    // MARK: - Release

    /// Clears `volume`'s desired attachment in memory. Every attachment column
    /// and the convergence deadline move together; the owning guarded mutation
    /// advances the generation in SQL.
    ///
    /// The bump is not bookkeeping: the agent drops a desired entry no newer
    /// than the one it last applied, so clearing the columns without it would
    /// leave the disk plugged into the guest forever.
    ///
    /// Nor is the deadline. Two of the three callers — the VM reap and the
    /// stranded-attachment sweep — go around `ResourceMutation.accept` and so
    /// never reach its `extendConvergenceDeadline`, which would leave the
    /// volume at `observedGeneration < generation` with nothing for the
    /// stuck-convergence sweep to grade: an agent that never reports the
    /// detach (the dead-agent case this exists for) would read as quietly
    /// un-converged instead of visibly degraded. Extending rather than setting
    /// keeps a longer mutation's runway, so the detach path's own stamp inside
    /// `accept` is unaffected.
    ///
    /// `status` is left alone. It is what the agent last observed, and the
    /// detach it will observe is what moves it.
    static func clearAttachment(_ volume: Volume) -> Volume {
        volume.replacing(
            attachedAgentId: .some(nil), vmID: .some(nil), deviceName: .some(nil),
            bootOrder: .some(nil), readonly: false)
            .extendingConvergenceDeadline(
                by: OperationResourceKind.volume.completionBudgetSeconds(for: .detach))
    }

    /// Releases every data volume attached to `vmID`, and returns their ids.
    ///
    /// Called from the VM reap inside the delete transaction: the guest is
    /// going away, so there is no hot-unplug to arrange — the volume's data is
    /// intact on the agent and the row becomes reusable. Unconditional on the
    /// volume's own state on purpose: `volumes.vm_id` is `ON DELETE RESTRICT`,
    /// so a row this skipped would fail the VM's delete, and "a dead agent must
    /// not make its VM undeletable" outranks every other consideration here.
    @discardableResult
    static func releaseDataVolumes(fromVM vmID: UUID, on db: any Database) async throws -> [UUID] {
        let attached = try await LegacyVolumeStore.volumes(
            attachment: .attachedTo(vmID), volumeType: .data, on: db)

        for volume in attached.sorted(by: {
            ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
        }) {
            guard var current = try await volume.lockingAndRefreshing(on: db) else { continue }
            // It may have moved while this VM's reap was reaching it. Only
            // release the attachment the query selected, never a newer one.
            guard current.vmID == vmID else { continue }
            let expectedGeneration = current.generation
            current = clearAttachment(current)
            let advance = try await current.advancingDesiredStateGeneration(
                expectedGeneration: expectedGeneration, on: db)
            guard case .applied = advance.outcome else {
                throw ConvergenceWriteError.unsupportedDatabase
            }
            try await advance.resource.save(on: db)
        }
        return attached.compactMap(\.id)
    }
}
