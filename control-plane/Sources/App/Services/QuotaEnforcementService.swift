import Foundation
import Vapor
import Fluent
import SQLKit

/// Enforces resource quotas across the VM and sandbox lifecycle. Resolves the
/// project/OU/org quotas that govern a workload (matching its environment),
/// rejects creations that would exceed an enabled quota, and keeps each quota's
/// reservation counters in step as workloads are created and deleted. Both
/// workload kinds draw vCPUs and memory from the same pools (issue #415); only
/// VMs consume storage, and each kind has its own count limit.
///
/// Scoping mirrors `ResourceQuota.calculateActualUsage` exactly — a workload is
/// reserved against precisely the quotas that measured usage would later count
/// it against (its project, its *direct* organizational unit, and its root
/// organization) — so reserved and actual figures cannot drift apart by
/// construction.
struct QuotaEnforcementService {

    /// All quotas that govern a workload created in `project` under `environment`.
    ///
    /// A quota applies when it is scoped to the workload's project, the project's
    /// direct organizational unit, or the project's root organization, AND its
    /// environment is unset (applies to every environment) or equal to the
    /// workload's environment.
    static func applicableQuotas(
        for project: Project,
        environment: String,
        on db: Database
    ) async throws -> [ResourceQuota] {
        guard let projectID = project.id else { return [] }
        let ouID = project.$organizationalUnit.id
        let orgID = try await project.getRootOrganizationId(on: db)

        return try await ResourceQuota.query(on: db)
            .group(.or) { scope in
                scope.filter(\.$project.$id == projectID)
                if let ouID {
                    scope.filter(\.$organizationalUnit.$id == ouID)
                }
                if let orgID {
                    scope.filter(\.$organization.$id == orgID)
                }
            }
            .group(.or) { env in
                env.filter(\.$environment == nil)
                env.filter(\.$environment == environment)
            }
            .all()
    }

    /// Checks every applicable quota and reserves the VM's resources against each.
    ///
    /// Throws `Abort(.forbidden)` naming the offending quota if any *enabled* quota
    /// cannot accommodate the VM; disabled quotas never block but still track the
    /// reservation so re-enabling them reflects existing VMs. Call inside the same
    /// transaction as the VM insert so a rejection — or a later failure to persist
    /// the VM — rolls the reservations back atomically.
    ///
    /// Each quota's counters are first resynced to real in-scope usage so the
    /// admission check has an accurate baseline even for a quota created *after* some
    /// of its VMs already existed (whose reservations `createQuota` never backfilled).
    ///
    /// Concurrent creates that share a quota are serialized by a transaction-scoped
    /// advisory lock per applicable quota (see ``lockQuotas``): without it, two
    /// creates under `READ COMMITTED` could both read the same baseline, both pass
    /// the check, and over-commit the limit. The lock is held until the enclosing
    /// transaction commits or rolls back, so the second create re-reads a baseline
    /// that already includes the first.
    static func reserve(
        for project: Project,
        environment: String,
        vcpus: Int,
        memory: Int64,
        storage: Int64,
        on db: Database
    ) async throws {
        try await reserveWorkload(for: project, environment: environment, on: db) { quota in
            let check = quota.canAccommodateVM(vcpus: vcpus, memory: memory, storage: storage)
            guard check.allowed else { return check }
            try quota.reserveResources(vcpus: vcpus, memory: memory, storage: storage)
            return check
        }
    }

    /// Admission for resizing an existing VM (issue #568): only the *delta*
    /// is checked and reserved, since the VM's current sizing is already
    /// counted. Call inside the same transaction as the VM's sizing write and
    /// *before* it, so the resync baseline still reflects the old size.
    ///
    /// A pure shrink never fails admission, but still runs through here so
    /// the freed capacity is credited back immediately rather than at the
    /// next resync.
    static func reserveVMResize(
        for project: Project,
        environment: String,
        vcpuDelta: Int,
        memoryDelta: Int64,
        on db: Database
    ) async throws {
        try await reserveWorkload(for: project, environment: environment, on: db) { quota in
            let check = quota.canAccommodateVMResize(vcpuDelta: vcpuDelta, memoryDelta: memoryDelta)
            guard check.allowed else { return check }
            try quota.applyVMResize(vcpuDelta: vcpuDelta, memoryDelta: memoryDelta)
            return check
        }
    }

    /// Sandbox counterpart of `reserve`: same shared vCPU/memory pools, the
    /// sandbox count limit instead of the VM one, no storage (issue #415).
    static func reserveSandbox(
        for project: Project,
        environment: String,
        vcpus: Int,
        memory: Int64,
        on db: Database
    ) async throws {
        try await reserveWorkload(for: project, environment: environment, on: db) { quota in
            let check = quota.canAccommodateSandbox(vcpus: vcpus, memory: memory)
            guard check.allowed else { return check }
            try quota.reserveSandboxResources(vcpus: vcpus, memory: memory)
            return check
        }
    }

    /// Sandbox-snapshot counterpart (issue #426): snapshots persist real bytes
    /// in the shared storage pool, so admission checks `size` — the guest
    /// memory as an estimate, later replaced by the agent's actual figures —
    /// against every applicable quota's storage limit. Call inside the same
    /// transaction as the snapshot insert.
    static func reserveSandboxSnapshot(
        for project: Project,
        environment: String,
        size: Int64,
        on db: Database
    ) async throws {
        try await reserveWorkload(for: project, environment: environment, on: db) { quota in
            let check = quota.canAccommodateSnapshotStorage(size)
            guard check.allowed else { return check }
            try quota.reserveSnapshotStorage(size)
            return check
        }
    }

    /// Admission for a snapshot *export* (issue #428). The exported copy is a
    /// second physical copy of the same archive, so it draws its own `size`
    /// from the storage pool — without this, export was the one path that
    /// wrote unbounded bytes with no quota at all. Call inside the same
    /// transaction that opens the export operation.
    static func reserveSandboxSnapshotExport(
        for project: Project,
        environment: String,
        size: Int64,
        on db: Database
    ) async throws {
        try await reserveWorkload(for: project, environment: environment, on: db) { quota in
            let check = quota.canAccommodateSnapshotStorage(size)
            guard check.allowed else { return check }
            try quota.reserveSnapshotStorage(size)
            return check
        }
    }

    /// Post-completion validation for sandbox snapshots (issue #426):
    /// admission reserved an *estimate*, so once the agent reports actual
    /// sizes the caller re-checks the pool. Resyncs every applicable quota to
    /// real usage and returns the name of the first enabled quota whose
    /// storage pool is now over-committed — the caller deletes the snapshot
    /// rather than keeping storage past the limit. Nil when everything fits.
    static func storageOverCommit(
        projectID: UUID,
        environment: String,
        on db: Database
    ) async throws -> String? {
        guard let project = try await Project.find(projectID, on: db) else { return nil }
        let quotas = try await applicableQuotas(for: project, environment: environment, on: db)
        // No advisory lock: like `releaseWorkload`, this runs outside the
        // admission transaction and resync-to-real-usage is idempotent.
        var violated: String?
        for quota in quotas {
            try await resyncReservations(quota, on: db)
            try await quota.save(on: db)
            if violated == nil, quota.isEnabled, quota.reservedStorage > quota.maxStorage {
                violated = quota.name
            }
        }
        return violated
    }

    /// Shared check-then-reserve sequence over every applicable quota:
    /// advisory-lock, resync each quota to real usage, dry-run `apply` on all
    /// of them (mutating nothing on rejection), then apply and save. `apply`
    /// returns the admission verdict and, when allowed, records the
    /// reservation on the quota.
    private static func reserveWorkload(
        for project: Project,
        environment: String,
        on db: Database,
        apply: (ResourceQuota) throws -> (allowed: Bool, reason: String?)
    ) async throws {
        let quotas = try await applicableQuotas(for: project, environment: environment, on: db)

        // Serialize concurrent reservations that touch any of these quotas before
        // reading the baseline, so the check-then-reserve sequence is atomic per quota.
        try await lockQuotas(quotas, on: db)

        // Resync every quota to real usage, then validate all of them before mutating
        // any, so a rejection never leaves a partial reservation even within the
        // enclosing transaction. `apply` only mutates when the check passes, and a
        // thrown Abort unwinds the enclosing transaction, so the two-phase loop
        // below never commits a partial application.
        for quota in quotas {
            try await resyncReservations(quota, on: db)
        }

        for quota in quotas {
            let check = try apply(quota)
            guard check.allowed else {
                // Prefix with the quota name so the reason always contains "quota"
                // (the frontend links to /quotas on any /quota/i match, and the
                // count messages otherwise omit the word) and the operator can see
                // exactly which limit was hit.
                throw Abort(.forbidden, reason: "Quota '\(quota.name)' exceeded: \(check.reason ?? "limit reached")")
            }
        }

        // Persists the resynced baselines plus the incoming workload; after its row
        // is inserted this equals each quota's true in-scope usage.
        for quota in quotas {
            try await quota.save(on: db)
        }
    }

    /// Recomputes every quota governing `vm` from the workloads still in its scope.
    ///
    /// Call *after* the VM row is deleted so the deleted VM drops out of the recount.
    /// Recomputing (rather than decrementing the VM's own numbers) keeps a delete from
    /// erasing reservations that belong to other workloads — e.g. when the quota was
    /// created after some VMs already existed and so never counted them in the first
    /// place.
    static func release(
        for vm: VM,
        on db: Database
    ) async throws {
        try await releaseWorkload(projectID: vm.$project.id, environment: vm.environment, on: db)
    }

    /// Sandbox counterpart of `release(for vm:)`: call *after* the sandbox row
    /// is deleted.
    static func release(
        for sandbox: Sandbox,
        on db: Database
    ) async throws {
        try await releaseWorkload(projectID: sandbox.$project.id, environment: sandbox.environment, on: db)
    }

    private static func releaseWorkload(projectID: UUID, environment: String, on db: Database) async throws {
        guard let project = try await Project.find(projectID, on: db) else { return }
        let quotas = try await applicableQuotas(for: project, environment: environment, on: db)

        for quota in quotas {
            try await resyncReservations(quota, on: db)
            try await quota.save(on: db)
        }
    }

    /// Takes a transaction-scoped advisory lock on each quota so concurrent
    /// creates that share a quota serialize their check-then-reserve sequence.
    ///
    /// Postgres only: `pg_advisory_xact_lock` is held until the enclosing
    /// transaction ends, giving cross-replica serialization (every replica shares
    /// the same Postgres) without a persisted lock row. Locks are taken in a stable
    /// (sorted) id order so two creates touching an overlapping set of quotas can't
    /// deadlock by acquiring them in opposite orders. On SQLite (local tests) there
    /// is no advisory-lock primitive and writes already serialize on the database
    /// file, so this is a no-op.
    private static func lockQuotas(_ quotas: [ResourceQuota], on db: Database) async throws {
        guard let sql = db as? SQLDatabase, sql.dialect.name == "postgresql" else { return }
        let keys = quotas.compactMap { $0.id?.uuidString }.sorted()
        for key in keys {
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtext(\(bind: key)))").run()
        }
    }

    /// Sets a quota's reservation counters to the exact usage of the VMs and
    /// sandboxes currently in its scope. Sums the raw `Int64` byte fields (not the
    /// lossy GB figures in `QuotaUsage`) so memory/storage stay byte-accurate. Does
    /// not persist — the caller saves.
    private static func resyncReservations(_ quota: ResourceQuota, on db: Database) async throws {
        let (_, vms, sandboxes) = try await quota.calculateActualUsage(on: db)
        quota.reservedVCPUs = vms.reduce(0) { $0 + $1.cpu } + sandboxes.reduce(0) { $0 + $1.cpus }
        quota.reservedMemory = vms.reduce(Int64(0)) { $0 + $1.memory } + sandboxes.reduce(Int64(0)) { $0 + $1.memory }
        // Storage: VM disks plus sandbox snapshot artifacts (issue #426).
        quota.reservedStorage =
            vms.reduce(Int64(0)) { $0 + $1.disk } + (try await quota.sandboxSnapshotStorageInScope(on: db))
        quota.vmCount = vms.count
        quota.sandboxCount = sandboxes.count
    }
}
