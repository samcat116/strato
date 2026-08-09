import Fluent
import SQLKit

/// Everything the schema owes before a volume can be charged against a resource
/// quota (STR-181).
///
/// The blocker was never accounting, it was scoping. `QuotaScope.predicate` is
/// one SQL fragment over `project_id` **and** `environment`, shared by every
/// aggregate so all of them measure exactly the same rows, and neither `volumes`
/// nor `volume_snapshots` had an environment to filter on. `vm_snapshots` and
/// `sandbox_snapshots` denormalize theirs for precisely this reason; these two
/// now do the same, backfilled from each row's project so an existing volume
/// lands in the environment its project would have given it.
///
/// Also here, because they are the same upgrade:
///
/// * `volume_snapshots.observed_size_bytes` — the overlay footprint a v39 agent
///   re-measures per report and the API exposes for observability and billing.
///   It does not replace the quota reservation: `size` remains the parent-sized
///   bound because an overlay can grow without another admission point.
/// * `resource_quotas.max_volumes` / `volume_count` — an optional count limit
///   beside `max_vms` and `max_sandboxes`.
/// * `idx_volume_snapshots_project_id`. `vm_snapshots` and `sandbox_snapshots`
///   both got one in their create migrations for the quota aggregate;
///   `volume_snapshots` never had a reason to until now, and the aggregate runs
///   under the per-quota advisory lock on every workload create. `volumes` needs
///   nothing: its `unique (project_id, name)` already leads with the column.
///
/// **`max_volumes` is nullable, and unset means no count limit.** The two
/// existing count columns are required, and matching them would have meant
/// backfilling from `max_vms` — the only plausible seed and the wrong one, since
/// a deployment that gives each VM a couple of data disks has more volumes than
/// VMs and would come out of this upgrade refusing creates against a limit
/// nobody chose. Bytes are the ceiling that matters; the count is there for an
/// operator who wants it.
struct AddVolumeQuotaAccounting: AsyncMigration {
    struct UnsupportedDatabase: Error {}

    /// `(index name, CREATE INDEX body)`, in the `AddHotPathIndexes` shape so
    /// `revert` drops exactly what `prepare` created and a test can assert the
    /// migrated schema carries it.
    static let indexes: [(name: String, definition: String)] = [
        // The volume-snapshot half of the storage aggregate, run under the
        // per-quota advisory lock on every VM, sandbox and volume create.
        ("idx_volume_snapshots_project_id", "volume_snapshots (project_id)")
    ]

    /// The two tables that gain an `environment`.
    static let environmentTables = ["volumes", "volume_snapshots"]

    /// Fills the new column from each row's project. Its own step so a test can
    /// drive it against rows written in the pre-migration shape; a project always
    /// has a `default_environment`, so it leaves no NULL for the `SET NOT NULL`
    /// that follows to trip over.
    func backfillEnvironments(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }
        for table in Self.environmentTables {
            try await sql.raw(
                """
                UPDATE \(ident: table) SET environment = p.default_environment
                FROM projects p
                WHERE p.id = \(ident: table).project_id AND \(ident: table).environment IS NULL
                """
            ).run()
        }
    }

    /// Initializes the two reservation counters this migration changes from the
    /// same canonical measurement used by every later admission and resync.
    /// Recomputing the whole storage cache is intentional: adding only the new
    /// volume terms to a possibly stale cache would preserve whatever drift the
    /// previous build left behind.
    func backfillQuotaCounters(on database: Database) async throws {
        for quota in try await ResourceQuota.query(on: database).all() {
            try await QuotaEnforcementService.resyncReservations(quota, on: database)
            try await quota.save(on: database)
        }
    }

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        // Add nullable, backfill from the owning project, then tighten — the
        // `AddTrustDomainToAgentIdentities` sequence.
        //
        // The default goes on *last*, and the order is load-bearing in both
        // directions. Adding the column with one would fill every existing row
        // before the backfill could read `IS NULL`, so no volume would land in
        // its project's environment. Leaving it off entirely makes a `NOT NULL`
        // column with no default, which breaks any insert that predates the
        // column — `MigrateVMDisksToVolumes` writes `volumes` through a frozen
        // schema snapshot that cannot know about it. In the real migration order
        // that one runs first and the column does not exist yet, but the
        // fallback is what keeps that from being a coincidence, and it is the
        // same shape `AddProjectToVM` gave `vms.environment`.
        for table in Self.environmentTables {
            try await sql.raw("ALTER TABLE \(ident: table) ADD COLUMN environment text").run()
        }
        try await backfillEnvironments(on: database)
        for table in Self.environmentTables {
            try await sql.raw("ALTER TABLE \(ident: table) ALTER COLUMN environment SET NOT NULL").run()
            try await sql.raw(
                "ALTER TABLE \(ident: table) ALTER COLUMN environment SET DEFAULT 'development'"
            ).run()
        }

        try await database.schema(VolumeSnapshot.schema)
            .field("observed_size_bytes", .int64)
            .update()

        try await database.schema("resource_quotas")
            .field("max_volumes", .int)
            .update()
        try await database.schema("resource_quotas")
            .field("volume_count", .int, .required, .sql(.default(0)))
            .update()

        // Backfill both caches rather than leaving existing volumes and
        // snapshots invisible until an unrelated mutation happens to resync the
        // row. Runs after the environment and quota columns above, which the
        // canonical aggregate reads.
        try await backfillQuotaCounters(on: database)

        for index in Self.indexes {
            try await sql.raw(
                SQLQueryString("CREATE INDEX IF NOT EXISTS \(index.name) ON \(index.definition)")
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        for index in Self.indexes {
            try await sql.raw(SQLQueryString("DROP INDEX IF EXISTS \(index.name)")).run()
        }

        try await database.schema("resource_quotas")
            .deleteField("volume_count")
            .update()
        try await database.schema("resource_quotas")
            .deleteField("max_volumes")
            .update()

        try await database.schema(VolumeSnapshot.schema)
            .deleteField("observed_size_bytes")
            .update()

        for table in Self.environmentTables {
            try await sql.raw("ALTER TABLE \(ident: table) DROP COLUMN environment").run()
        }
    }
}
