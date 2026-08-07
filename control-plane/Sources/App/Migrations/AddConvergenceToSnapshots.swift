import Fluent
import SQLKit
import StratoShared

/// The columns that make a snapshot artifact a `ConvergingResource` and a
/// `FinalizableResource` (ADR 0001 stage 8, STR-150).
///
/// Snapshots and checkpoints were the last durable *artifacts* driven by
/// imperative agent RPCs. The six of them are gone; an artifact now has a
/// desired state the agent converges on, a generation guarding the order it is
/// applied in, and a finalizer list that keeps its row alive until an agent
/// confirms the bytes are gone. The columns mirror `volumes` exactly, so
/// `ResourceMutation`, the stuck-convergence sweep and the operations façade
/// work on one without a single new branch.
///
/// Two columns have no volume counterpart:
///
/// * `expires_at` is the retention answer stage 8 was asked to design. A
///   fire-and-forget RPC left nothing behind to expire; a durable artifact
///   object does, and without it every checkpoint a CI pipeline takes lives
///   until a human deletes it. Backfilled to NULL — "keep until deleted", which
///   is what every artifact taken before this migration meant.
/// * `export_desired` (sandbox snapshots only) turns "export this" from a verb
///   into a placement fact. Backfilled from `exported_at`, so a snapshot that
///   was already exported keeps its copy wanted rather than being read as one
///   whose export should be withdrawn.
///
/// `volume_snapshots.agent_id` is new too: a volume snapshot's placement used to
/// be re-derived from its volume's replica per request. A desired entry has to
/// appear in exactly one agent's sync, so it is recorded.
struct AddConvergenceToSnapshots: AsyncMigration {
    /// One `CHECK` per new `@Enum` column, installed here rather than in
    /// `EnforcePersistedEnumValues` for the reason `AddConvergenceToVolumes`
    /// gives: that migration had already run when these columns were added, so
    /// it will never pick them up.
    static var desiredStatusConstraints: [PersistedEnumConstraint] {
        [VolumeSnapshot.schema, VMSnapshot.schema, SandboxSnapshot.schema].map { table in
            PersistedEnumConstraint(
                table: table,
                column: "desired_status",
                allowedValues: DesiredSnapshotStatus.allCases.map(\.rawValue),
                defaultValue: DesiredSnapshotStatus.present.rawValue
            )
        } + [
            PersistedEnumConstraint(
                table: SandboxSnapshot.schema,
                column: "capture_mode",
                allowedValues: SandboxSnapshotMode.allCases.map(\.rawValue),
                defaultValue: SandboxSnapshotMode.resume.rawValue
            )
        ]
    }

    /// The status values each table treats as "the bytes are really here", for
    /// the `observed_generation` backfill below.
    private static let restingStatuses: [String: [String]] = [
        VolumeSnapshot.schema: ["available"],
        VMSnapshot.schema: ["ready"],
        SandboxSnapshot.schema: ["ready"],
    ]

    func prepare(on database: any Database) async throws {
        for table in Self.restingStatuses.keys.sorted() {
            var schema = database.schema(table)
                .field("desired_status", .string, .required, .custom("DEFAULT 'Present'"))
                .field("generation", .int64, .required, .custom("DEFAULT 0"))
                .field("observed_generation", .int64, .required, .custom("DEFAULT 0"))
                .field("convergence_phase", .string)
                .field("failed_generation", .int64)
                .field("convergence_deadline", .datetime)
                // Postgres-only and deliberately unbranched, like
                // `AddConvergenceToVolumes`: `ResourceFinalizerService` clears
                // tokens with `array_remove`, so a column created under any
                // other dialect would be one no participant could ever clear.
                .field("finalizers", .array(of: .string), .required, .custom("DEFAULT '{}'"))
                .field("expires_at", .datetime)
            if table == VolumeSnapshot.schema {
                schema = schema.field("agent_id", .string)
            }
            if table == SandboxSnapshot.schema {
                schema =
                    schema
                    .field("export_desired", .bool, .required, .custom("DEFAULT false"))
                    // The capture mode has to be durable: it is a create
                    // strategy read off the desired entry, and an entry is
                    // re-assembled on every sync — including ones long after
                    // the request that made it. Existing rows were all captured
                    // and are past the point where it is read, so the default
                    // is the harmless one.
                    .field("capture_mode", .string, .required, .custom("DEFAULT 'resume'"))
            }
            try await schema.update()
        }

        guard let sql = database as? any SQLDatabase else { return }

        // Every existing artifact starts at generation 1 with its desired state
        // read off the status it was left in, and `observed_generation` set to 1
        // only for artifacts in a resting state — the ones an agent demonstrably
        // wrote. One stranded mid-capture by the old imperative path gets 0
        // instead, so the first sync after the upgrade re-drives it rather than
        // declaring a half-finished capture converged.
        //
        // That re-drive is safe *because* capture is a create strategy: it runs
        // only while the artifact is absent from the host, so an artifact whose
        // bytes did land is adopted at generation 1 rather than re-captured.
        for (table, resting) in Self.restingStatuses.sorted(by: { $0.key < $1.key }) {
            let restingList = resting.map { "'\($0)'" }.joined(separator: ", ")
            try await sql.raw(
                """
                UPDATE \(ident: table)
                SET desired_status = CASE WHEN status::text = 'deleting' THEN 'Absent' ELSE 'Present' END,
                    generation = 1,
                    observed_generation =
                        CASE WHEN status::text IN (\(unsafeRaw: restingList)) THEN 1 ELSE 0 END
                """
            ).run()

        }

        // A volume snapshot's agent, from the volume's replica (the lookup the
        // request path used to do per call), falling back to the volume's
        // legacy `hypervisor_id`. A snapshot whose volume has neither is left
        // unplaced: nothing can converge it, and inventing a host would put its
        // teardown in some other agent's hands.
        try await sql.raw(
            """
            UPDATE \(ident: VolumeSnapshot.schema) AS s
            SET agent_id = COALESCE(
                (SELECT r.agent_id FROM volume_replicas r
                 WHERE r.volume_id = s.volume_id ORDER BY r.created_at LIMIT 1),
                v.hypervisor_id)
            FROM \(ident: Volume.schema) AS v
            WHERE v.id = s.volume_id
            """
        ).run()

        // A delete already in flight across the upgrade is waiting on its agent
        // to confirm absence, exactly like a terminating volume — without the
        // token its row would be reaped by the orphaned-terminating sweep
        // before the bytes were gone.
        //
        // After the `agent_id` backfill above, not before: a volume snapshot's
        // agent column does not exist until then, and stamping on a NULL would
        // silently skip exactly the rows that need the token.
        for table in Self.restingStatuses.keys.sorted() {
            try await sql.raw(
                """
                UPDATE \(ident: table)
                SET finalizers = ARRAY[\(bind: ResourceFinalizer.agentAbsent.rawValue)]
                WHERE desired_status = 'Absent' AND agent_id IS NOT NULL
                """
            ).run()
        }

        // An already-exported snapshot still wants its copy.
        try await sql.raw(
            """
            UPDATE \(ident: SandboxSnapshot.schema)
            SET export_desired = true
            WHERE exported_at IS NOT NULL
            """
        ).run()

        // Sync assembly and observed-state application both scan each table by
        // `agent_id`, once per poll and once per report — the two hottest
        // recurring paths in the control plane. Without an index that is three
        // sequential scans per agent per cycle, growing with every snapshot the
        // fleet has ever taken (`AddHotPathIndexes`' reasoning, applied to the
        // columns this migration creates).
        for (table, index) in Self.agentIndexes {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS \(unsafeRaw: index) ON \(ident: table) (agent_id)"
            ).run()
        }

        // After the backfill, so the validation half has real values to check
        // rather than the column default alone.
        for constraint in Self.desiredStatusConstraints {
            try await EnforcePersistedEnumValues.prepare(constraint, on: database)
        }
    }

    /// The `agent_id` index per table. `vm_snapshots` and `sandbox_snapshots`
    /// have carried the column since they were created, so this is where all
    /// three finally get covered.
    static let agentIndexes: [(table: String, index: String)] = [
        (VolumeSnapshot.schema, "idx_volume_snapshots_agent_id"),
        (VMSnapshot.schema, "idx_vm_snapshots_agent_id"),
        (SandboxSnapshot.schema, "idx_sandbox_snapshots_agent_id"),
    ]

    func revert(on database: any Database) async throws {
        for constraint in Self.desiredStatusConstraints {
            try await EnforcePersistedEnumValues.revert(constraint, on: database)
        }
        if let sql = database as? any SQLDatabase {
            for (_, index) in Self.agentIndexes {
                try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: index)").run()
            }
        }
        for table in Self.restingStatuses.keys.sorted() {
            var schema = database.schema(table)
                .deleteField("desired_status")
                .deleteField("generation")
                .deleteField("observed_generation")
                .deleteField("convergence_phase")
                .deleteField("failed_generation")
                .deleteField("convergence_deadline")
                .deleteField("finalizers")
                .deleteField("expires_at")
            if table == VolumeSnapshot.schema {
                schema = schema.deleteField("agent_id")
            }
            if table == SandboxSnapshot.schema {
                schema = schema.deleteField("export_desired").deleteField("capture_mode")
            }
            try await schema.update()
        }
    }
}
