import Foundation
import Vapor
import Fluent
import SQLKit

/// Enforces resource quotas across the VM lifecycle. Resolves the project/OU/org
/// quotas that govern a VM (matching its environment), rejects creations that would
/// exceed an enabled quota, and keeps each quota's reservation counters in step as
/// VMs are created and deleted.
///
/// Scoping mirrors `ResourceQuota.calculateActualUsage` exactly — a VM is reserved
/// against precisely the quotas that measured usage would later count it against
/// (its project, its *direct* organizational unit, and its root organization) — so
/// reserved and actual figures cannot drift apart by construction.
struct QuotaEnforcementService {

    /// All quotas that govern a VM created in `project` under `environment`.
    ///
    /// A quota applies when it is scoped to the VM's project, the project's direct
    /// organizational unit, or the project's root organization, AND its environment
    /// is unset (applies to every environment) or equal to the VM's environment.
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
        let quotas = try await applicableQuotas(for: project, environment: environment, on: db)

        // Serialize concurrent reservations that touch any of these quotas before
        // reading the baseline, so the check-then-reserve sequence is atomic per quota.
        try await lockQuotas(quotas, on: db)

        // Resync every quota to real usage, then validate all of them before mutating
        // any, so a rejection never leaves a partial reservation even within the
        // enclosing transaction.
        for quota in quotas {
            try await resyncReservations(quota, on: db)
        }

        for quota in quotas {
            let check = quota.canAccommodateVM(vcpus: vcpus, memory: memory, storage: storage)
            guard check.allowed else {
                // Prefix with the quota name so the reason always contains "quota"
                // (the frontend links to /quotas on any /quota/i match, and the
                // VM-count message otherwise omits the word) and the operator can see
                // exactly which limit was hit.
                throw Abort(.forbidden, reason: "Quota '\(quota.name)' exceeded: \(check.reason ?? "limit reached")")
            }
        }

        // Adds the incoming VM to the resynced baseline; after the VM row is inserted
        // this equals the quota's true in-scope usage.
        for quota in quotas {
            try quota.reserveResources(vcpus: vcpus, memory: memory, storage: storage)
            try await quota.save(on: db)
        }
    }

    /// Recomputes every quota governing `vm` from the VMs still in its scope.
    ///
    /// Call *after* the VM row is deleted so the deleted VM drops out of the recount.
    /// Recomputing (rather than decrementing the VM's own numbers) keeps a delete from
    /// erasing reservations that belong to other VMs — e.g. when the quota was created
    /// after some VMs already existed and so never counted them in the first place.
    static func release(
        for vm: VM,
        on db: Database
    ) async throws {
        let project = try await vm.$project.get(on: db)
        let quotas = try await applicableQuotas(for: project, environment: vm.environment, on: db)

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

    /// Sets a quota's reservation counters to the exact usage of the VMs currently in
    /// its scope. Sums the raw `Int64` byte fields (not the lossy GB figures in
    /// `QuotaUsage`) so memory/storage stay byte-accurate. Does not persist — the
    /// caller saves.
    private static func resyncReservations(_ quota: ResourceQuota, on db: Database) async throws {
        let (_, vms) = try await quota.calculateActualUsage(on: db)
        quota.reservedVCPUs = vms.reduce(0) { $0 + $1.cpu }
        quota.reservedMemory = vms.reduce(0) { $0 + $1.memory }
        quota.reservedStorage = vms.reduce(0) { $0 + $1.disk }
        quota.vmCount = vms.count
    }
}
