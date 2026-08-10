import Foundation
import Vapor
import Fluent
import SQLKit

/// Enforces resource quotas across the VM, sandbox, volume and network lifecycle.
/// Resolves the project/OU/org quotas that govern a workload (matching its
/// environment), rejects creations that would exceed an enabled quota, and keeps
/// each quota's reservation counters in step as workloads are created and
/// deleted. VMs and sandboxes draw vCPUs and memory from the same pools (issue
/// #415); VMs, snapshot artifacts and volumes draw from the same storage pool
/// (STR-181), and each family has its own count limit — the volume one optional.
///
/// Scoping mirrors ``QuotaScope`` exactly — a workload is reserved against
/// precisely the quotas that measured usage would later count it against (its
/// project, its organizational unit and every ancestor OU up to the root, and
/// its root organization) — so reserved and actual figures cannot drift apart
/// by construction.
struct QuotaEnforcementService {

    /// All quotas that govern a workload created in `project` under `environment`.
    ///
    /// A quota applies when it is scoped to the workload's project, the project's
    /// organizational unit *or any ancestor OU up to the root*, or the project's
    /// root organization, AND its environment is unset (applies to every
    /// environment) or equal to the workload's environment.
    static func applicableQuotas(
        for project: Project,
        environment: String,
        on db: Database
    ) async throws -> [ResourceQuota] {
        try await applicableQuotas(for: project, environmentScope: environment, on: db)
    }

    /// Quotas governing project-wide infrastructure such as logical networks.
    /// Environment-scoped quotas are excluded because a network can be consumed
    /// by workloads from every environment (STR-236).
    static func applicableProjectWideQuotas(
        for project: Project,
        on db: Database
    ) async throws -> [ResourceQuota] {
        try await applicableQuotas(for: project, environmentScope: nil, on: db)
    }

    /// The project-wide ancestor quotas that survive when `project` is
    /// deleted. Project-scoped quotas are excluded because the same foreign-key
    /// cascade that removes the project removes those quota rows too.
    ///
    /// Call inside the project-deletion transaction, before deleting the
    /// project. Locking serializes the later recount with network admissions in
    /// sibling projects that share an organization or OU quota.
    static func lockedProjectWideAncestorQuotas(
        for project: Project,
        on db: Database
    ) async throws -> [ResourceQuota] {
        try await lockProjectNetworkMutations(for: project, on: db)
        let quotas = try await applicableProjectWideQuotas(for: project, on: db)
            .filter { $0.$project.id == nil }
        try await lockQuotas(quotas, on: db)
        return quotas
    }

    /// `environmentScope == nil` means project-wide and selects only global
    /// quotas. A concrete environment selects both global and matching quotas.
    private static func applicableQuotas(
        for project: Project,
        environmentScope: String?,
        on db: Database
    ) async throws -> [ResourceQuota] {
        guard let projectID = project.id else { return [] }
        let ouID = project.$organizationalUnit.id
        let orgID = try await project.getRootOrganizationId(on: db)

        // Resolve the project's direct OU and every ancestor OU up to the root, so
        // a quota on any intermediate folder is enforced — not just the direct OU
        // (issue #645). Kept symmetric with `QuotaScope`, which measures a folder
        // quota over that folder and all of its descendants.
        var ouIDs: [UUID] = []
        if let ouID {
            if let ou = try await OrganizationalUnit.find(ouID, on: db) {
                ouIDs = ou.ancestorAndSelfOUIDs()
            } else {
                ouIDs = [ouID]
            }
        }

        let query = ResourceQuota.query(on: db)
            .group(.or) { scope in
                scope.filter(\.$project.$id == projectID)
                if !ouIDs.isEmpty {
                    scope.filter(\.$organizationalUnit.$id ~~ ouIDs)
                }
                if let orgID {
                    scope.filter(\.$organization.$id == orgID)
                }
            }
        if let environmentScope {
            query.group(.or) { env in
                env.filter(\.$environment == nil)
                env.filter(\.$environment == environmentScope)
            }
        } else {
            query.filter(\.$environment == nil)
        }
        return try await query.all()
    }

    /// Checks every applicable quota and atomically reserves the VM plus its
    /// canonical boot volume. CPU, memory and VM count belong to the VM row;
    /// storage and volume count belong to the managed Volume row. Keeping both
    /// checks in one resync/lock pass prevents the second reservation from
    /// overwriting the first one's cached counters.
    ///
    /// Throws `Abort(.forbidden)` naming the offending quota if any *enabled* quota
    /// cannot accommodate the VM; disabled quotas never block but still track the
    /// reservation so re-enabling them reflects existing VMs. Call inside the same
    /// transaction as the VM insert so a rejection — or a later failure to persist
    /// the VM — rolls the reservations back atomically.
    ///
    /// Each quota's counters are first resynced to real in-scope usage so the
    /// admission check has an accurate baseline no matter how stale the stored
    /// counters are — they are only ever a cache of the last resync.
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
            let vmCheck = quota.canAccommodateVM(vcpus: vcpus, memory: memory, storage: 0)
            guard vmCheck.allowed else { return vmCheck }
            let volumeCheck = quota.canAccommodateVolume(size: storage)
            guard volumeCheck.allowed else { return volumeCheck }
            try quota.reserveResources(vcpus: vcpus, memory: memory, storage: 0)
            try quota.reserveVolumeResources(size: storage)
            return vmCheck
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
            let check = quota.canAccommodateStorage(size, for: "the snapshot")
            guard check.allowed else { return check }
            try quota.reserveStorage(size, for: "the snapshot")
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
            let check = quota.canAccommodateStorage(size, for: "the snapshot")
            guard check.allowed else { return check }
            try quota.reserveStorage(size, for: "the snapshot")
            return check
        }
    }

    /// Admission for a full-VM checkpoint (issue #564). The machine state a
    /// checkpoint writes draws from the shared storage pool, so admission
    /// checks `size` — the VM's memory grant as an estimate, later replaced by
    /// what the agent actually wrote — against every applicable quota's
    /// storage limit. Call inside the same transaction as the snapshot insert.
    static func reserveVMSnapshot(
        for project: Project,
        environment: String,
        size: Int64,
        on db: Database
    ) async throws {
        try await reserveWorkload(for: project, environment: environment, on: db) { quota in
            let check = quota.canAccommodateStorage(size, for: "the snapshot")
            guard check.allowed else { return check }
            try quota.reserveStorage(size, for: "the snapshot")
            return check
        }
    }

    /// Admission for creating or cloning a volume (STR-181). Checks the
    /// provisioned `size` against every applicable quota's storage pool, plus
    /// the optional volume count limit. Call inside the same transaction as the
    /// volume insert, so a rejection — or a later failure to persist the row —
    /// rolls the reservation back atomically.
    ///
    /// A clone is a full copy of the source's file, so it is admitted exactly
    /// like a create: the source's size, charged to the new row.
    static func reserveVolume(
        for project: Project,
        environment: String,
        size: Int64,
        on db: Database
    ) async throws {
        try await reserveWorkload(for: project, environment: environment, on: db) { quota in
            let check = quota.canAccommodateVolume(size: size)
            guard check.allowed else { return check }
            try quota.reserveVolumeResources(size: size)
            return check
        }
    }

    /// Admission for a logical network (STR-236). Only quotas spanning every
    /// environment apply. Call before resolver-index allocation and inside the
    /// network insert transaction so a refusal consumes no fleet-wide address.
    static func reserveNetwork(
        for project: Project,
        on db: Database
    ) async throws {
        try await lockProjectNetworkMutations(for: project, on: db)
        let quotas = try await applicableProjectWideQuotas(for: project, on: db)
        try await reserveResource(for: project, quotas: quotas, on: db) { quota in
            let check = quota.canAccommodateNetworks()
            guard check.allowed else { return check }
            try quota.reserveNetworkResources()
            return check
        }
    }

    /// Validates the networks carried by a project moving between hierarchy
    /// paths and returns every project-wide quota whose cached usage must be
    /// refreshed after the move (STR-236).
    ///
    /// Quotas shared by both paths already count the project and require no new
    /// capacity. Destination-only quotas are resynced while the project still
    /// belongs to the source, then checked against the whole incoming network
    /// count. The union is locked in stable order so network admissions in
    /// either hierarchy cannot interleave with the transfer's check and recount.
    static func validateNetworkTransfer(
        networkCount: Int,
        sourceQuotas: [ResourceQuota],
        destinationQuotas: [ResourceQuota],
        on db: Database
    ) async throws -> [ResourceQuota] {
        let sourceIDs = Set(sourceQuotas.compactMap(\.id))
        let destinationOnly = destinationQuotas.filter { quota in
            quota.id.map { !sourceIDs.contains($0) } ?? false
        }

        var affectedByID: [UUID: ResourceQuota] = [:]
        for quota in sourceQuotas + destinationQuotas {
            if let id = quota.id {
                affectedByID[id] = quota
            }
        }
        let affected = Array(affectedByID.values)
        try await lockQuotas(affected, on: db)

        for quota in destinationOnly {
            try await resyncReservations(quota, on: db)
            let check = quota.canAccommodateNetworks(networkCount)
            guard check.allowed else {
                throw Abort(
                    .forbidden,
                    reason: "Quota '\(quota.name)' exceeded: \(check.reason ?? "limit reached")")
            }
        }
        return affected
    }

    /// Admission for growing a volume (STR-181): only the *delta* is checked and
    /// reserved, since the volume's current size is already counted, and the
    /// count limit is untouched because no volume is being added. Call inside the
    /// same transaction as the size write and *before* it, so the resync baseline
    /// still reflects the old size — the same contract as ``reserveVMResize``.
    ///
    /// Resize is grow-only today, so this never credits back; the floor in
    /// ``ResourceQuota/reserveStorage(_:for:)`` covers it if that changes.
    static func reserveVolumeResize(
        for project: Project,
        environment: String,
        sizeDelta: Int64,
        reason: String = "the volume resize",
        on db: Database
    ) async throws {
        try await reserveWorkload(for: project, environment: environment, on: db) { quota in
            let check = quota.canAccommodateStorage(sizeDelta, for: reason)
            guard check.allowed else { return check }
            try quota.reserveStorage(sizeDelta, for: reason)
            return check
        }
    }

    /// Admission for a volume snapshot (STR-181). Call inside the same
    /// transaction as the snapshot insert.
    ///
    /// `size` is the **parent volume's whole size**, not a guess at how big the
    /// overlay will get, and that is the enforcement point for the whole family:
    /// an overlay grows toward its parent as the volume diverges, with no API
    /// call to refuse along the way, so a snapshot is admitted only when the pool
    /// could absorb it fully grown. That bound remains reserved for the lifetime
    /// of the snapshot; the agent's live footprint is reported separately for
    /// observability and billing rather than releasing admission capacity.
    static func reserveVolumeSnapshot(
        for project: Project,
        environment: String,
        size: Int64,
        on db: Database
    ) async throws {
        try await reserveWorkload(for: project, environment: environment, on: db) { quota in
            let check = quota.canAccommodateStorage(size, for: "the snapshot")
            guard check.allowed else { return check }
            try quota.reserveStorage(size, for: "the snapshot")
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
        try await reserveResource(for: project, quotas: quotas, on: db, apply: apply)
    }

    private static func reserveResource(
        for project: Project,
        quotas: [ResourceQuota],
        on db: Database,
        apply: (ResourceQuota) throws -> (allowed: Bool, reason: String?)
    ) async throws {
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

        // Baseline after resync but before this workload is applied: the
        // quota.threshold_exceeded webhook (issue #559) fires only when this
        // admission crosses a threshold the baseline was still under.
        let baselines = quotas.map(QuotaUsageSnapshot.init(of:))

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
        for (quota, baseline) in zip(quotas, baselines) {
            try await quota.save(on: db)
            // Same transaction as the reservation: the threshold event commits
            // iff the admission commits.
            try await WebhookEvents.enqueueQuotaThresholds(
                quota: quota, baseline: baseline, project: project, on: db)
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

    /// Volume counterpart (STR-181): call *after* the volume row is deleted.
    ///
    /// One call covers the volume's snapshots too, because deleting the row
    /// cascades them and this recomputes rather than decrements.
    static func release(
        for volume: Volume,
        on db: Database
    ) async throws {
        try await releaseWorkload(projectID: volume.$project.id, environment: volume.environment, on: db)
    }

    /// Logical-network counterpart: call after the network row is deleted so
    /// the canonical project-wide recount observes the released slot (STR-236).
    static func release(
        for network: LogicalNetwork,
        on db: Database
    ) async throws {
        let projectID = network.$project.id
        try await lockProjectNetworkMutations(projectID: projectID, on: db)
        guard let project = try await Project.find(projectID, on: db) else { return }
        let quotas = try await applicableProjectWideQuotas(for: project, on: db)
        try await lockQuotas(quotas, on: db)
        try await resyncAndSaveReservations(quotas, on: db)
    }

    private static func releaseWorkload(projectID: UUID, environment: String, on db: Database) async throws {
        guard let project = try await Project.find(projectID, on: db) else { return }
        let quotas = try await applicableQuotas(for: project, environment: environment, on: db)

        try await resyncAndSaveReservations(quotas, on: db)
    }

    /// Recounts and persists a set of already-resolved quotas. This accepts the
    /// captured ancestor rows from a project deletion because their scope can
    /// no longer be derived from the deleted project after its cascade.
    static func resyncAndSaveReservations(
        _ quotas: [ResourceQuota],
        on db: Database
    ) async throws {
        for quota in quotas {
            try await resyncReservations(quota, on: db)
            try await quota.save(on: db)
        }
    }

    /// Serializes network inserts/deletes with hierarchy moves and project deletion.
    /// A quota lock alone is insufficient when the source hierarchy has no
    /// quota: a concurrent insert could otherwise land after a transfer counts
    /// the project's networks but before the project changes parent.
    ///
    /// Every path takes this project lock before quota locks, avoiding a lock
    /// cycle between network creation, transfer, and deletion.
    static func lockProjectNetworkMutations(
        for project: Project,
        on db: Database
    ) async throws {
        guard let projectID = project.id else { return }
        try await lockProjectNetworkMutations(projectID: projectID, on: db)
    }

    static func lockProjectNetworkMutations(
        projectID: UUID,
        on db: Database
    ) async throws {
        try await lockAdvisoryKey("project-network:\(projectID.uuidString)", on: db)
    }

    /// Takes a transaction-scoped advisory lock on each quota so concurrent
    /// creates that share a quota serialize their check-then-reserve sequence.
    ///
    /// Postgres only: `pg_advisory_xact_lock` is held until the enclosing
    /// transaction ends, giving cross-replica serialization (every replica shares
    /// the same Postgres) without a persisted lock row. Locks are taken in a stable
    /// (sorted) id order so two creates touching an overlapping set of quotas can't
    /// deadlock by acquiring them in opposite orders.
    private static func lockQuotas(_ quotas: [ResourceQuota], on db: Database) async throws {
        let keys = quotas.compactMap { $0.id?.uuidString }.sorted()
        for key in keys {
            try await lockAdvisoryKey(key, on: db)
        }
    }

    private static func lockAdvisoryKey(_ key: String, on db: Database) async throws {
        guard let sql = db as? SQLDatabase, sql.dialect.name == "postgresql" else { return }
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtext(\(bind: key)))").run()
    }

    /// Sets a quota's reservation counters to the exact usage of the VMs,
    /// sandboxes and volumes currently in its scope. Takes the raw `Int64` byte totals (not the
    /// lossy GB figures in `QuotaUsage`) so memory/storage stay byte-accurate. Does
    /// not persist — the caller saves.
    ///
    /// The counters are a cache, correct only as of the last resync: nothing
    /// maintains them outside this file and the quota controller's write paths, and
    /// a row written any other way (a migration, a fixture) starts at zero however
    /// full its scope is. Any code whose *verdict* depends on how much of a quota is
    /// in use — including the controller's update and delete integrity guards
    /// (issue #742) — must resync first rather than read the stored fields.
    ///
    /// A fixed set of aggregate queries over an already-resolved scope: on the
    /// admission path this runs under the per-quota advisory lock, so every row
    /// it doesn't load is lock time every other create in the organization
    /// doesn't wait for (issue #692).
    static func resyncReservations(_ quota: ResourceQuota, on db: Database) async throws {
        let scope = try await QuotaUsageAggregator.scope(of: quota, on: db)
        let usage = try await QuotaUsageAggregator.measure(scope, on: db)
        quota.reservedVCPUs = usage.vcpus
        quota.reservedMemory = usage.memoryBytes
        // Storage: managed volumes (including every VM boot disk), their
        // snapshots, sandbox snapshot artifacts, and full-VM checkpoint state.
        quota.reservedStorage = usage.storageBytes
        quota.vmCount = usage.vmCount
        quota.sandboxCount = usage.sandboxCount
        quota.volumeCount = usage.volumeCount
        quota.networkCount = usage.networkCount
    }
}
