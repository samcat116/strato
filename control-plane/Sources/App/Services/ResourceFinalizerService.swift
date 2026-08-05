import Fluent
import SQLKit
import Vapor

/// A resource whose deletion runs through finalizers: the row is marked
/// terminating, carries a list of outstanding cleanup tokens, and is removed
/// only once that list empties (ADR 0001, stage 3).
///
/// Divergence between the workload kinds lives in `reap` — what each one has
/// to tear down alongside its row — rather than in the finalizer bookkeeping,
/// which is identical for both.
protocol FinalizableResource: Model where IDValue == UUID {
    /// Cleanup tokens still outstanding for a terminating resource; empty for
    /// a live one. Persisted as a Postgres `text[]`.
    var finalizers: [String] { get set }

    /// The agent this resource is placed on, or nil if it never reached one.
    var hypervisorId: String? { get }

    /// Whether a `DELETE` has been accepted — desired state is `.absent`. Only
    /// a terminating resource reaps, so a stray `clear` on a live one is a
    /// no-op rather than a deletion.
    var isTerminating: Bool { get }

    /// Everything that must happen when the last finalizer clears: external
    /// cleanup first, then the row and the accounting that goes with it. Must
    /// tolerate running again after a crash partway through — the row is what
    /// records that it ran, so anything before the row's own removal can be
    /// repeated.
    static func reap(_ resource: Self, on db: any Database, app: Application) async throws
}

/// The finalizer bookkeeping shared by every terminating resource: stamping
/// the list at `DELETE` time, and clearing one participant's token — atomically
/// against other participants and other replicas — reaping the row when it was
/// the last one.
enum ResourceFinalizerService {

    /// The tokens a fresh deletion of `resource` stamps. A resource with no
    /// agent has nothing to confirm, so it stamps nothing and reaps on the
    /// first `clear` — which is how an unplaced VM still deletes immediately.
    static func tokens<R: FinalizableResource>(forDeleting resource: R) -> [ResourceFinalizer] {
        resource.hypervisorId == nil ? [] : [.agentAbsent]
    }

    /// Stamps the finalizer list for a deletion. Call in the same write that
    /// marks desired state `.absent`, *before* the mark: a resource already
    /// terminating keeps the list it has, because re-stamping would resurrect
    /// tokens their participants have already cleared. Does not persist.
    static func stampForDeletion<R: FinalizableResource>(_ resource: R) {
        guard !resource.isTerminating else { return }
        resource.finalizers = tokens(forDeleting: resource).map(\.rawValue)
    }

    /// Idempotently clears `token` from a terminating resource, reaping the row
    /// when it was the last one outstanding. Returns whether the row was
    /// removed.
    ///
    /// The removal is a single `array_remove` statement rather than a
    /// read-modify-write: two participants clearing concurrently — on two
    /// replicas, in any order — would otherwise lose one of the updates and
    /// resurrect a token nothing will ever clear again.
    ///
    /// Clearing the token and reaping the row are two commits, not one. A crash
    /// in between leaves a terminating row with an empty list, which the
    /// participant's next trigger reaps: clearing an already-cleared token
    /// still reaps an empty list. That is the whole reason a participant is
    /// required to have a repeating trigger — for `agent.absent`, every
    /// observed-state report that omits the workload.
    @discardableResult
    static func clear<R: FinalizableResource>(
        _ token: ResourceFinalizer,
        from resource: R,
        on db: any Database,
        app: Application
    ) async throws -> Bool {
        guard resource.isTerminating else { return false }
        let id = try resource.requireID()

        guard let sql = db as? any SQLDatabase else {
            throw FinalizerError.unsupportedDatabase
        }

        let row = try await sql.raw(
            """
            UPDATE \(ident: R.schema)
            SET finalizers = array_remove(finalizers, \(bind: token.rawValue))
            WHERE id = \(bind: id)
            RETURNING coalesce(array_length(finalizers, 1), 0) AS remaining
            """
        ).first(decoding: Remaining.self)

        // No row: another replica already reaped it. Nothing to do, and
        // nothing to report as removed — whoever removed it logged it.
        guard let row else { return false }

        resource.finalizers.removeAll { $0 == token.rawValue }

        guard row.remaining == 0 else { return false }

        // Shutdown's drain cancels the background tasks the direct-deletion
        // path runs on, and `reap` opens a transaction on a database that is
        // about to be torn down. Fail rather than return: the row is still
        // standing, so reporting a removal would be a lie, and the caller's
        // verdict recording bails on a drained application anyway.
        try Task.checkCancellation()

        try await R.reap(resource, on: db, app: app)
        return true
    }

    /// `RETURNING` reads the post-update row, so `remaining` is what is left
    /// *after* this participant's token is gone.
    private struct Remaining: Decodable {
        let remaining: Int
    }

    enum FinalizerError: Error, CustomStringConvertible {
        case unsupportedDatabase

        var description: String {
            switch self {
            case .unsupportedDatabase:
                return "Finalizer bookkeeping requires an SQL database"
            }
        }
    }
}

// MARK: - VM

extension VM: FinalizableResource {
    var isTerminating: Bool { desiredStatus == .absent }

    static func reap(_ vm: VM, on db: any Database, app: Application) async throws {
        let vmID = try vm.requireID()

        // Bindings first, unlike the delete-then-revoke order the other
        // controllers use: the revoke reads the VM's checkpoints, whose rows
        // the delete below cascades away (STR-112).
        try await db.transaction { db in
            try await ResourceBindingCleanup.revokeBindings(forDeletedVM: vmID, on: db)
            try await vm.delete(on: db)
            try await QuotaEnforcementService.release(for: vm, on: db)
        }

        if let agentId = vm.hypervisorId {
            await app.coordination.releaseReservation(agentId: agentId, vmId: vmID.uuidString)
        }
    }
}

// MARK: - Sandbox

extension Sandbox: FinalizableResource {
    var isTerminating: Bool { desiredStatus == .absent }

    static func reap(_ sandbox: Sandbox, on db: any Database, app: Application) async throws {
        let sandboxID = try sandbox.requireID()

        // Exported snapshot objects first: the snapshot rows cascade with the
        // sandbox row below (issue #428).
        await SandboxController.cleanUpExportedSnapshotObjects(for: sandboxID, app: app)

        // Bindings first, for the same reason the exported objects go first:
        // the revoke reads the snapshot rows the delete cascades away
        // (STR-112).
        try await db.transaction { db in
            try await ResourceBindingCleanup.revokeBindings(forDeletedSandbox: sandboxID, on: db)
            try await sandbox.delete(on: db)
            try await QuotaEnforcementService.release(for: sandbox, on: db)
        }

        if let agentId = sandbox.hypervisorId {
            await app.coordination.releaseReservation(agentId: agentId, vmId: sandboxID.uuidString)
        }
    }
}
