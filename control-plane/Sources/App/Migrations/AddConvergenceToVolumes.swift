import Fluent
import SQLKit
import StratoShared

/// The columns that make a volume a `ConvergingResource` and a
/// `FinalizableResource` (ADR 0001 stage 5, STR-148).
///
/// Volumes were the last durable resource driven by imperative agent RPCs. The
/// six of them are gone; a volume now has a desired state the agent converges
/// on, a generation guarding the order it is applied in, and a finalizer list
/// that keeps its row alive until an agent confirms the data is gone. The
/// columns mirror `vms` exactly, so `ResourceMutation`, the stuck-convergence
/// sweep, and the operations façade work on a volume without a single new
/// branch.
///
/// `readonly` is the one column with no VM counterpart. `AttachVolumeRequest`
/// has always carried it and always thrown it away after handing it to the
/// attach RPC — which was survivable when attachment was an event, and is not
/// when it is a desired state the control plane must be able to restate on
/// every sync.
struct AddConvergenceToVolumes: AsyncMigration {
    /// The guard for the new `@Enum` column. Installed here rather than in
    /// `EnforcePersistedEnumValues` for the reason `EnforceSiteStatusEnum`
    /// exists: that migration had already run when this column was added, so it
    /// will never pick it up.
    static let desiredStatusConstraint = PersistedEnumConstraint(
        table: Volume.schema,
        column: "desired_status",
        allowedValues: DesiredVolumeStatus.allCases.map(\.rawValue),
        defaultValue: DesiredVolumeStatus.present.rawValue
    )

    func prepare(on database: any Database) async throws {
        try await database.schema(Volume.schema)
            .field("desired_status", .string, .required, .custom("DEFAULT 'Present'"))
            .field("generation", .int64, .required, .custom("DEFAULT 0"))
            .field("observed_generation", .int64, .required, .custom("DEFAULT 0"))
            .field("convergence_phase", .string)
            .field("failed_generation", .int64)
            .field("convergence_deadline", .datetime)
            // Postgres-only and deliberately unbranched, like
            // `AddFinalizersToWorkloads`: `ResourceFinalizerService` clears
            // tokens with `array_remove`, so a column created under any other
            // dialect would be one no participant could ever clear.
            .field("finalizers", .array(of: .string), .required, .custom("DEFAULT '{}'"))
            .field("readonly", .bool, .required, .custom("DEFAULT false"))
            .update()

        guard let sql = database as? any SQLDatabase else { return }

        // Backfill, in the order the columns depend on each other.
        //
        // Every existing volume starts at generation 1 with its desired state
        // read off the status it was left in, and `observed_generation` set to
        // 1 only for volumes in a resting state — the ones an agent demonstrably
        // realized. A volume stranded mid-operation by the old imperative path
        // gets 0 instead, so the first sync after the upgrade re-drives it from
        // scratch rather than declaring a half-finished create converged. That
        // recovery is the whole point of moving to a level-triggered loop, and
        // it is worth more here than preserving a status nobody can vouch for.
        try await sql.raw(
            """
            UPDATE \(ident: Volume.schema)
            SET desired_status = CASE WHEN status::text = 'deleting' THEN 'Absent' ELSE 'Present' END,
                generation = 1,
                observed_generation = CASE WHEN status::text IN ('available', 'attached') THEN 1 ELSE 0 END,
                readonly = false
            """
        ).run()

        // A delete already in flight across the upgrade is waiting on its agent
        // to confirm absence, exactly like a terminating VM — without the token
        // its row would be reaped by the orphaned-terminating sweep before the
        // data was gone.
        try await sql.raw(
            """
            UPDATE \(ident: Volume.schema)
            SET finalizers = ARRAY[\(bind: ResourceFinalizer.agentAbsent.rawValue)]
            WHERE desired_status = 'Absent' AND hypervisor_id IS NOT NULL
            """
        ).run()

        // `readonly` is unknowable for attachments that predate the column —
        // the value was passed to an RPC and never stored. `false` is both the
        // default every existing attach used and the safe direction to be wrong
        // in: a volume that should have been read-only is writable until the
        // operator re-attaches it, whereas guessing `true` would break a guest
        // that has been writing to it for months.

        // After the backfill, so the validation half of this has real values to
        // check rather than the column default alone.
        try await EnforcePersistedEnumValues.prepare(Self.desiredStatusConstraint, on: database)
    }

    func revert(on database: any Database) async throws {
        try await EnforcePersistedEnumValues.revert(Self.desiredStatusConstraint, on: database)
        try await database.schema(Volume.schema)
            .deleteField("desired_status")
            .deleteField("generation")
            .deleteField("observed_generation")
            .deleteField("convergence_phase")
            .deleteField("failed_generation")
            .deleteField("convergence_deadline")
            .deleteField("finalizers")
            .deleteField("readonly")
            .update()
    }
}
