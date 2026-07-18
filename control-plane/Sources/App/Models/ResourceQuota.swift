import Fluent
import Vapor
import Foundation

final class ResourceQuota: Model, @unchecked Sendable {
    static let schema = "resource_quotas"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    // Quota can apply to Organization, OU, or Project level
    @OptionalParent(key: "organization_id")
    var organization: Organization?

    @OptionalParent(key: "organizational_unit_id")
    var organizationalUnit: OrganizationalUnit?

    @OptionalParent(key: "project_id")
    var project: Project?

    // CPU limits
    @Field(key: "max_vcpus")
    var maxVCPUs: Int

    @Field(key: "reserved_vcpus")
    var reservedVCPUs: Int

    // Memory limits (in bytes)
    @Field(key: "max_memory")
    var maxMemory: Int64

    @Field(key: "reserved_memory")
    var reservedMemory: Int64

    // Storage limits (in bytes)
    @Field(key: "max_storage")
    var maxStorage: Int64

    @Field(key: "reserved_storage")
    var reservedStorage: Int64

    // VM count limits
    @Field(key: "max_vms")
    var maxVMs: Int

    @Field(key: "vm_count")
    var vmCount: Int

    // Sandbox count limits (issue #415). Sandboxes draw vCPUs/memory from the
    // same pools as VMs above; only the count limit is separate, so a quota
    // sized for N VMs isn't silently consumed by sandboxes.
    @Field(key: "max_sandboxes")
    var maxSandboxes: Int

    @Field(key: "sandbox_count")
    var sandboxCount: Int

    // Network limits
    @Field(key: "max_networks")
    var maxNetworks: Int

    @Field(key: "network_count")
    var networkCount: Int

    // Whether this quota is enabled
    @Field(key: "is_enabled")
    var isEnabled: Bool

    // Optional environment-specific quota (null means applies to all environments)
    @OptionalField(key: "environment")
    var environment: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        organizationID: UUID? = nil,
        organizationalUnitID: UUID? = nil,
        projectID: UUID? = nil,
        maxVCPUs: Int,
        maxMemory: Int64,
        maxStorage: Int64,
        maxVMs: Int,
        maxSandboxes: Int? = nil,
        maxNetworks: Int = 10,
        environment: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.$organization.id = organizationID
        self.$organizationalUnit.id = organizationalUnitID
        self.$project.id = projectID
        self.maxVCPUs = maxVCPUs
        self.reservedVCPUs = 0
        self.maxMemory = maxMemory
        self.reservedMemory = 0
        self.maxStorage = maxStorage
        self.reservedStorage = 0
        self.maxVMs = maxVMs
        self.vmCount = 0
        // Unspecified sandbox limit follows the VM count limit — the same
        // default the migration backfills for pre-existing quota rows.
        self.maxSandboxes = maxSandboxes ?? maxVMs
        self.sandboxCount = 0
        self.maxNetworks = maxNetworks
        self.networkCount = 0
        self.environment = environment
        self.isEnabled = isEnabled
    }
}

extension ResourceQuota: Content {}

// MARK: - Actual Usage Calculation

extension ResourceQuota {
    /// The project IDs within this quota's scope (its project, the projects of
    /// its organizational unit, or every project of its organization). Nil when
    /// the scoping entity no longer exists (e.g. deleted concurrently).
    private func scopedProjectIDs(on db: Database) async throws -> [UUID]? {
        if let projectID = $project.id {
            return [projectID]
        }
        if let ouID = $organizationalUnit.id {
            let projects = try await Project.query(on: db)
                .filter(\.$organizationalUnit.$id == ouID)
                .all()
            return projects.compactMap { $0.id }
        }
        if let orgID = $organization.id {
            guard let org = try await Organization.find(orgID, on: db) else { return nil }
            let allProjects = try await org.getAllProjects(on: db)
            return allProjects.compactMap { $0.id }
        }
        return []
    }

    /// Calculates the actual resource usage for this quota by aggregating the
    /// VMs *and sandboxes* within its scope (project, organizational unit, or
    /// organization) — both workload kinds draw vCPUs and memory from the same
    /// pools (issue #415); only VMs consume storage. Returns the computed
    /// usage along with the workloads it was derived from.
    func calculateActualUsage(on db: Database) async throws -> (usage: QuotaUsage, vms: [VM], sandboxes: [Sandbox]) {
        var vms: [VM] = []
        var sandboxes: [Sandbox] = []

        if let projectIDs = try await scopedProjectIDs(on: db), !projectIDs.isEmpty {
            let vmQuery = VM.query(on: db).filter(\.$project.$id ~~ projectIDs)
            let sandboxQuery = Sandbox.query(on: db).filter(\.$project.$id ~~ projectIDs)
            if let environment = environment {
                vmQuery.filter(\.$environment == environment)
                sandboxQuery.filter(\.$environment == environment)
            }
            vms = try await vmQuery.all()
            sandboxes = try await sandboxQuery.all()
        }

        // Calculate actual usage across both workload kinds. Storage counts
        // VM disks plus sandbox snapshot artifacts (issue #426) — sandboxes
        // themselves reserve no storage, but their checkpoints persist real
        // bytes in the shared pool.
        let totalVCPUs = vms.reduce(0) { $0 + $1.cpu } + sandboxes.reduce(0) { $0 + $1.cpus }
        let totalMemory = vms.reduce(Int64(0)) { $0 + $1.memory } + sandboxes.reduce(Int64(0)) { $0 + $1.memory }
        let totalStorage =
            vms.reduce(Int64(0)) { $0 + $1.disk } + (try await sandboxSnapshotStorageInScope(on: db))

        let actualUsage = QuotaUsage(
            vcpus: totalVCPUs,
            memoryGB: Double(totalMemory) / 1024 / 1024 / 1024,
            storageGB: Double(totalStorage) / 1024 / 1024 / 1024,
            vms: vms.count,
            sandboxes: sandboxes.count,
            networks: 0  // TODO: Implement network counting when networking is added
        )

        return (actualUsage, vms, sandboxes)
    }

    /// Total sandbox-snapshot storage within this quota's scope (issue #426):
    /// the sum of `size` over non-error snapshots of in-scope projects.
    /// `creating` rows carry the admission estimate (the sandbox's guest
    /// memory) until the agent reports actual sizes; `error` rows are
    /// excluded — a failed checkpoint removes its partial artifacts.
    func sandboxSnapshotStorageInScope(on db: Database) async throws -> Int64 {
        guard let projectIDs = try await scopedProjectIDs(on: db), !projectIDs.isEmpty else { return 0 }
        let query = SandboxSnapshot.query(on: db)
            .filter(\.$project.$id ~~ projectIDs)
            .filter(\.$status != .error)
        if let environment = environment {
            query.filter(\.$environment == environment)
        }
        let snapshots = try await query.all()
        return snapshots.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
    }
}

// MARK: - Computed Properties

extension ResourceQuota {
    var availableVCPUs: Int {
        return maxVCPUs - reservedVCPUs
    }

    var availableMemory: Int64 {
        return maxMemory - reservedMemory
    }

    var availableStorage: Int64 {
        return maxStorage - reservedStorage
    }

    var availableVMs: Int {
        return maxVMs - vmCount
    }

    var availableSandboxes: Int {
        return maxSandboxes - sandboxCount
    }

    var availableNetworks: Int {
        return maxNetworks - networkCount
    }

    var cpuUtilizationPercent: Double {
        guard maxVCPUs > 0 else { return 0 }
        return Double(reservedVCPUs) / Double(maxVCPUs) * 100
    }

    var memoryUtilizationPercent: Double {
        guard maxMemory > 0 else { return 0 }
        return Double(reservedMemory) / Double(maxMemory) * 100
    }

    var storageUtilizationPercent: Double {
        guard maxStorage > 0 else { return 0 }
        return Double(reservedStorage) / Double(maxStorage) * 100
    }

    var vmUtilizationPercent: Double {
        guard maxVMs > 0 else { return 0 }
        return Double(vmCount) / Double(maxVMs) * 100
    }

    var sandboxUtilizationPercent: Double {
        guard maxSandboxes > 0 else { return 0 }
        return Double(sandboxCount) / Double(maxSandboxes) * 100
    }
}

// MARK: - Helper Methods

extension ResourceQuota {
    /// Check if a VM creation would exceed quota limits
    func canAccommodateVM(vcpus: Int, memory: Int64, storage: Int64) -> (allowed: Bool, reason: String?) {
        if !isEnabled {
            return (true, nil)
        }

        if reservedVCPUs + vcpus > maxVCPUs {
            return (false, "Insufficient vCPU quota: \(availableVCPUs) available, \(vcpus) requested")
        }

        if reservedMemory + memory > maxMemory {
            let availableGB = Double(availableMemory) / 1024 / 1024 / 1024
            let requestedGB = Double(memory) / 1024 / 1024 / 1024
            return (
                false,
                "Insufficient memory quota: \(String(format: "%.2f", availableGB))GB available, \(String(format: "%.2f", requestedGB))GB requested"
            )
        }

        if reservedStorage + storage > maxStorage {
            let availableGB = Double(availableStorage) / 1024 / 1024 / 1024
            let requestedGB = Double(storage) / 1024 / 1024 / 1024
            return (
                false,
                "Insufficient storage quota: \(String(format: "%.2f", availableGB))GB available, \(String(format: "%.2f", requestedGB))GB requested"
            )
        }

        if vmCount >= maxVMs {
            return (false, "VM limit reached: \(maxVMs) VMs allowed")
        }

        return (true, nil)
    }

    /// Check if a sandbox creation would exceed quota limits. Sandboxes draw
    /// vCPUs and memory from the same pools as VMs but have their own count
    /// limit and reserve no storage (issue #415).
    func canAccommodateSandbox(vcpus: Int, memory: Int64) -> (allowed: Bool, reason: String?) {
        if !isEnabled {
            return (true, nil)
        }

        if reservedVCPUs + vcpus > maxVCPUs {
            return (false, "Insufficient vCPU quota: \(availableVCPUs) available, \(vcpus) requested")
        }

        if reservedMemory + memory > maxMemory {
            let availableGB = Double(availableMemory) / 1024 / 1024 / 1024
            let requestedGB = Double(memory) / 1024 / 1024 / 1024
            return (
                false,
                "Insufficient memory quota: \(String(format: "%.2f", availableGB))GB available, \(String(format: "%.2f", requestedGB))GB requested"
            )
        }

        if sandboxCount >= maxSandboxes {
            return (false, "Sandbox limit reached: \(maxSandboxes) sandboxes allowed")
        }

        return (true, nil)
    }

    /// Reserve resources for a VM
    func reserveResources(vcpus: Int, memory: Int64, storage: Int64) throws {
        let check = canAccommodateVM(vcpus: vcpus, memory: memory, storage: storage)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }

        reservedVCPUs += vcpus
        reservedMemory += memory
        reservedStorage += storage
        vmCount += 1
    }

    /// Reserve resources for a sandbox: same vCPU/memory pools as VMs, its own
    /// count, no storage.
    func reserveSandboxResources(vcpus: Int, memory: Int64) throws {
        let check = canAccommodateSandbox(vcpus: vcpus, memory: memory)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }

        reservedVCPUs += vcpus
        reservedMemory += memory
        sandboxCount += 1
    }

    /// Check whether `bytes` of sandbox-snapshot storage fits (issue #426).
    /// Snapshots draw from the same storage pool as VM disks.
    func canAccommodateSnapshotStorage(_ bytes: Int64) -> (allowed: Bool, reason: String?) {
        if !isEnabled {
            return (true, nil)
        }
        if reservedStorage + bytes > maxStorage {
            let availableGB = Double(availableStorage) / 1024 / 1024 / 1024
            let requestedGB = Double(bytes) / 1024 / 1024 / 1024
            return (
                false,
                "Insufficient storage quota for the snapshot: \(String(format: "%.2f", availableGB))GB available, \(String(format: "%.2f", requestedGB))GB requested"
            )
        }
        return (true, nil)
    }

    /// Reserve sandbox-snapshot storage (issue #426).
    func reserveSnapshotStorage(_ bytes: Int64) throws {
        let check = canAccommodateSnapshotStorage(bytes)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }
        reservedStorage += bytes
    }

    /// Release resources when a VM is deleted
    func releaseResources(vcpus: Int, memory: Int64, storage: Int64) {
        reservedVCPUs = max(0, reservedVCPUs - vcpus)
        reservedMemory = max(0, reservedMemory - memory)
        reservedStorage = max(0, reservedStorage - storage)
        vmCount = max(0, vmCount - 1)
    }

    /// Update reserved resources when a VM is resized
    func updateReservation(
        oldVCPUs: Int, oldMemory: Int64, oldStorage: Int64,
        newVCPUs: Int, newMemory: Int64, newStorage: Int64
    ) throws {
        // Calculate deltas
        let vcpuDelta = newVCPUs - oldVCPUs
        let memoryDelta = newMemory - oldMemory
        let storageDelta = newStorage - oldStorage

        // Check if increase is allowed
        if vcpuDelta > 0 || memoryDelta > 0 || storageDelta > 0 {
            let check = canAccommodateVM(
                vcpus: max(0, vcpuDelta),
                memory: max(0, memoryDelta),
                storage: max(0, storageDelta)
            )
            if !check.allowed {
                throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded for resize")
            }
        }

        // Update reservations
        reservedVCPUs += vcpuDelta
        reservedMemory += memoryDelta
        reservedStorage += storageDelta
    }
}

// MARK: - Validations

extension ResourceQuota {
    func validate() throws {
        // Ensure quota belongs to exactly one entity
        let parentCount = [
            $organization.id != nil,
            $organizationalUnit.id != nil,
            $project.id != nil,
        ].filter { $0 }.count

        if parentCount != 1 {
            throw Abort(
                .badRequest, reason: "Resource quota must belong to exactly one entity (organization, OU, or project)")
        }

        // Validate limits are positive
        if maxVCPUs <= 0 || maxMemory <= 0 || maxStorage <= 0 || maxVMs <= 0 || maxSandboxes <= 0 {
            throw Abort(.badRequest, reason: "All resource limits must be positive")
        }

        // Validate reserved doesn't exceed max
        if reservedVCPUs > maxVCPUs || reservedMemory > maxMemory || reservedStorage > maxStorage || vmCount > maxVMs
            || sandboxCount > maxSandboxes
        {
            throw Abort(.badRequest, reason: "Reserved resources cannot exceed maximum limits")
        }
    }
}

// MARK: - DTOs

struct CreateResourceQuotaRequest: Content {
    let name: String
    let maxVCPUs: Int
    let maxMemoryGB: Double
    let maxStorageGB: Double
    let maxVMs: Int
    /// Sandbox count limit; defaults to `maxVMs` when omitted.
    let maxSandboxes: Int?
    let maxNetworks: Int?
    let environment: String?
    let isEnabled: Bool?
}

struct UpdateResourceQuotaRequest: Content {
    let name: String?
    let maxVCPUs: Int?
    let maxMemoryGB: Double?
    let maxStorageGB: Double?
    let maxVMs: Int?
    let maxSandboxes: Int?
    let maxNetworks: Int?
    let isEnabled: Bool?
}

struct ResourceQuotaResponse: Content {
    let id: UUID?
    let name: String
    let entityType: String  // "organization", "ou", or "project"
    let entityId: UUID
    let environment: String?
    let isEnabled: Bool
    let limits: ResourceLimits
    let usage: ResourceUsage
    let utilization: ResourceUtilization
    let createdAt: Date?

    struct ResourceLimits: Content {
        let maxVCPUs: Int
        let maxMemoryGB: Double
        let maxStorageGB: Double
        let maxVMs: Int
        let maxSandboxes: Int
        let maxNetworks: Int
    }

    struct ResourceUsage: Content {
        let reservedVCPUs: Int
        let reservedMemoryGB: Double
        let reservedStorageGB: Double
        let vmCount: Int
        let sandboxCount: Int
        let networkCount: Int
    }

    struct ResourceUtilization: Content {
        let cpuPercent: Double
        let memoryPercent: Double
        let storagePercent: Double
        let vmPercent: Double
        let sandboxPercent: Double
    }

    init(from quota: ResourceQuota) {
        self.id = quota.id
        self.name = quota.name

        // Determine entity type and ID
        if let orgId = quota.$organization.id {
            self.entityType = "organization"
            self.entityId = orgId
        } else if let ouId = quota.$organizationalUnit.id {
            self.entityType = "ou"
            self.entityId = ouId
        } else if let projId = quota.$project.id {
            self.entityType = "project"
            self.entityId = projId
        } else {
            // This should never happen due to validation
            self.entityType = "unknown"
            self.entityId = UUID()
        }

        self.environment = quota.environment
        self.isEnabled = quota.isEnabled

        self.limits = ResourceLimits(
            maxVCPUs: quota.maxVCPUs,
            maxMemoryGB: Double(quota.maxMemory) / 1024 / 1024 / 1024,
            maxStorageGB: Double(quota.maxStorage) / 1024 / 1024 / 1024,
            maxVMs: quota.maxVMs,
            maxSandboxes: quota.maxSandboxes,
            maxNetworks: quota.maxNetworks
        )

        self.usage = ResourceUsage(
            reservedVCPUs: quota.reservedVCPUs,
            reservedMemoryGB: Double(quota.reservedMemory) / 1024 / 1024 / 1024,
            reservedStorageGB: Double(quota.reservedStorage) / 1024 / 1024 / 1024,
            vmCount: quota.vmCount,
            sandboxCount: quota.sandboxCount,
            networkCount: quota.networkCount
        )

        self.utilization = ResourceUtilization(
            cpuPercent: quota.cpuUtilizationPercent,
            memoryPercent: quota.memoryUtilizationPercent,
            storagePercent: quota.storageUtilizationPercent,
            vmPercent: quota.vmUtilizationPercent,
            sandboxPercent: quota.sandboxUtilizationPercent
        )

        self.createdAt = quota.createdAt
    }
}

struct ResourceUsageResponse: Content {
    let totalVCPUs: Int
    let totalMemoryGB: Double
    let totalStorageGB: Double
    let totalVMs: Int
}

// MARK: - Additional DTOs

struct QuotaLimits: Content {
    let maxVCPUs: Int
    let maxMemoryGB: Double
    let maxStorageGB: Double
    let maxVMs: Int
    let maxSandboxes: Int
    let maxNetworks: Int
}

struct QuotaUsage: Content {
    let vcpus: Int
    let memoryGB: Double
    let storageGB: Double
    let vms: Int
    let sandboxes: Int
    let networks: Int
}

struct QuotaUtilization: Content {
    let cpuPercent: Double
    let memoryPercent: Double
    let storagePercent: Double
    let vmPercent: Double
    let sandboxPercent: Double
}

struct QuotaUsageResponse: Content {
    let quotaId: UUID
    let quotaName: String
    let limits: QuotaLimits
    let reserved: QuotaUsage
    let actual: QuotaUsage
    let utilization: QuotaUtilization
    let vmsByEnvironment: [String: Int]
    let vmsByStatus: [String: Int]
    let isEnabled: Bool
    let environment: String?
}
