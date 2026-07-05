import Foundation
import Vapor
import Fluent

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
    /// Note: reservation reads are not row-locked, so under `READ COMMITTED` two
    /// concurrent creates against the same quota could both pass the check and
    /// slightly over-commit. Enforcement is best-effort accounting rather than a hard
    /// admission gate, and the transaction still guarantees each create is all-or-nothing.
    static func reserve(
        for project: Project,
        environment: String,
        vcpus: Int,
        memory: Int64,
        storage: Int64,
        on db: Database
    ) async throws {
        let quotas = try await applicableQuotas(for: project, environment: environment, on: db)

        // First pass validates every quota before mutating any, so a rejection never
        // leaves a partial reservation even within the enclosing transaction.
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

        for quota in quotas {
            try quota.reserveResources(vcpus: vcpus, memory: memory, storage: storage)
            try await quota.save(on: db)
        }
    }

    /// Releases a VM's reserved resources from every quota that currently governs it.
    ///
    /// Resolves the same scope as `reserve` and clamps at zero. Assumes quotas are
    /// configured before the VMs they govern (the usual case, and enforced by the
    /// controller's refusal to delete a quota with live reservations); a quota
    /// created between two VMs' lifecycles is a known accounting edge case.
    static func release(
        for vm: VM,
        on db: Database
    ) async throws {
        let project = try await vm.$project.get(on: db)
        let quotas = try await applicableQuotas(for: project, environment: vm.environment, on: db)

        for quota in quotas {
            quota.releaseResources(vcpus: vm.cpu, memory: vm.memory, storage: vm.disk)
            try await quota.save(on: db)
        }
    }
}
