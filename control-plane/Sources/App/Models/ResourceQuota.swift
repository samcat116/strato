import Fluent
import Vapor
import Foundation

/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
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

    /// Volume count limit (STR-181), or nil for no limit.
    ///
    /// Optional where the other two counts are required, and that asymmetry is
    /// the point: `max_vms` was the only plausible backfill and it is the wrong
    /// one, since a deployment that gives each VM a data disk or two has more
    /// volumes than VMs and would come out of the upgrade refusing creates
    /// against a limit nobody chose. Bytes (`maxStorage`) are the ceiling that
    /// protects the host; this is here for an operator who wants a count too.
    @OptionalField(key: "max_volumes")
    var maxVolumes: Int?

    @Field(key: "volume_count")
    var volumeCount: Int

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
        maxVolumes: Int? = nil,
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
        // No default: an unspecified volume limit is *no* volume limit, not one
        // inferred from the VM count.
        self.maxVolumes = maxVolumes
        self.volumeCount = 0
        self.maxNetworks = maxNetworks
        self.networkCount = 0
        self.environment = environment
        self.isEnabled = isEnabled
    }
}

extension ResourceQuota: Content {}

// MARK: - Actual Usage Calculation

extension ResourceQuota {
    /// The actual resource usage of the VMs *and sandboxes* within this quota's
    /// scope (project, organizational unit, or organization) — both workload
    /// kinds draw vCPUs and memory from the same pools (issue #415); only VMs
    /// consume storage, alongside sandbox snapshots.
    ///
    /// Measured with SQL aggregates rather than by loading the workloads; see
    /// ``QuotaUsageAggregator``. A caller that measures the same quota more
    /// than once, or that also needs a breakdown, should resolve the scope once
    /// with `QuotaUsageAggregator.scope(of:on:)` and reuse it.
    func calculateActualUsage(on db: Database) async throws -> QuotaUsage {
        try await QuotaUsageAggregator.measure(quota: self, on: db).asQuotaUsage
    }

    /// Total sandbox-snapshot storage within this quota's scope (issue #426).
    func sandboxSnapshotStorageInScope(on db: Database) async throws -> Int64 {
        let scope = try await QuotaUsageAggregator.scope(of: self, on: db)
        return try await QuotaUsageAggregator.snapshotStorageBytes(in: scope, on: db)
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

    /// Nil when no volume count limit is set — distinct from 0%, which would
    /// read as "a limit, entirely unused".
    var volumeUtilizationPercent: Double? {
        guard let maxVolumes, maxVolumes > 0 else { return nil }
        return Double(volumeCount) / Double(maxVolumes) * 100
    }
}

// MARK: - Helper Methods

extension ResourceQuota {
    /// Check if a VM creation would exceed quota limits
    func canAccommodateVM(vcpus: Int, memory: Int64, storage: Int64) -> (allowed: Bool, reason: String?) {
        if !isEnabled {
            return (true, nil)
        }

        let (newVCPUs, vcpusOverflowed) = reservedVCPUs.addingReportingOverflow(vcpus)
        if vcpusOverflowed || newVCPUs > maxVCPUs {
            return (false, "Insufficient vCPU quota: \(availableVCPUs) available, \(vcpus) requested")
        }

        let (newMemory, memoryOverflowed) = reservedMemory.addingReportingOverflow(memory)
        if memoryOverflowed || newMemory > maxMemory {
            let availableGB = Double(availableMemory) / 1024 / 1024 / 1024
            let requestedGB = Double(memory) / 1024 / 1024 / 1024
            return (
                false,
                "Insufficient memory quota: \(String(format: "%.2f", availableGB))GiB available, \(String(format: "%.2f", requestedGB))GiB requested"
            )
        }

        let (newStorage, storageOverflowed) = reservedStorage.addingReportingOverflow(storage)
        if storageOverflowed || newStorage > maxStorage {
            let availableGB = Double(availableStorage) / 1024 / 1024 / 1024
            let requestedGB = Double(storage) / 1024 / 1024 / 1024
            return (
                false,
                "Insufficient storage quota: \(String(format: "%.2f", availableGB))GiB available, \(String(format: "%.2f", requestedGB))GiB requested"
            )
        }

        if vmCount >= maxVMs {
            return (false, "VM limit reached: \(maxVMs) VMs allowed")
        }

        return (true, nil)
    }

    /// Check whether growing an existing VM would exceed quota limits
    /// (issue #568). The deltas draw from the same vCPU/memory pools as a
    /// create, but the VM count is unchanged — a resize adds no VM — so the
    /// count limit is deliberately not consulted, and a shrink (negative
    /// delta) always fits.
    func canAccommodateVMResize(vcpuDelta: Int, memoryDelta: Int64) -> (allowed: Bool, reason: String?) {
        if !isEnabled {
            return (true, nil)
        }

        if vcpuDelta > 0 {
            let (newVCPUs, overflowed) = reservedVCPUs.addingReportingOverflow(vcpuDelta)
            if overflowed || newVCPUs > maxVCPUs {
                return (false, "Insufficient vCPU quota: \(availableVCPUs) available, \(vcpuDelta) requested")
            }
        }

        if memoryDelta > 0 {
            let (newMemory, overflowed) = reservedMemory.addingReportingOverflow(memoryDelta)
            if overflowed || newMemory > maxMemory {
                let availableGB = Double(availableMemory) / 1024 / 1024 / 1024
                let requestedGB = Double(memoryDelta) / 1024 / 1024 / 1024
                return (
                    false,
                    "Insufficient memory quota: \(String(format: "%.2f", availableGB))GiB available, "
                        + "\(String(format: "%.2f", requestedGB))GiB requested"
                )
            }
        }

        return (true, nil)
    }

    /// Applies a resize's deltas to this quota's reservations. Shrinks floor
    /// at zero: the counters are resynced to real usage before any admission
    /// check, so a transiently negative figure would be meaningless anyway.
    func applyVMResize(vcpuDelta: Int, memoryDelta: Int64) throws {
        let check = canAccommodateVMResize(vcpuDelta: vcpuDelta, memoryDelta: memoryDelta)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }

        reservedVCPUs = max(reservedVCPUs + vcpuDelta, 0)
        reservedMemory = max(reservedMemory + memoryDelta, 0)
    }

    /// Check if a sandbox creation would exceed quota limits. Sandboxes draw
    /// vCPUs and memory from the same pools as VMs but have their own count
    /// limit and reserve no storage (issue #415).
    func canAccommodateSandbox(vcpus: Int, memory: Int64) -> (allowed: Bool, reason: String?) {
        if !isEnabled {
            return (true, nil)
        }

        let (newVCPUs, vcpusOverflowed) = reservedVCPUs.addingReportingOverflow(vcpus)
        if vcpusOverflowed || newVCPUs > maxVCPUs {
            return (false, "Insufficient vCPU quota: \(availableVCPUs) available, \(vcpus) requested")
        }

        let (newMemory, memoryOverflowed) = reservedMemory.addingReportingOverflow(memory)
        if memoryOverflowed || newMemory > maxMemory {
            let availableGB = Double(availableMemory) / 1024 / 1024 / 1024
            let requestedGB = Double(memory) / 1024 / 1024 / 1024
            return (
                false,
                "Insufficient memory quota: \(String(format: "%.2f", availableGB))GiB available, \(String(format: "%.2f", requestedGB))GiB requested"
            )
        }

        if sandboxCount >= maxSandboxes {
            return (false, "Sandbox limit reached: \(maxSandboxes) sandboxes allowed")
        }

        return (true, nil)
    }

    /// Applies one reservation to a counter without ever trapping (issue
    /// #826). A passing admission check rules out overflow on an *enabled*
    /// quota, but a disabled one never blocks and still tracks the reservation,
    /// so an unbounded operand reaches these adds with no check in front of it.
    ///
    /// Overflow saturates and the result floors at zero — the same floor
    /// ``applyVMResize`` uses, and for the same reason: these counters are only
    /// a cache of measured usage, resynced to real usage before every admission
    /// check, so a clamped figure is meaningless-but-harmless where a trap
    /// kills the replica.
    private static func reserving<T: FixedWidthInteger>(_ counter: T, _ addend: T) -> T {
        let (sum, overflowed) = counter.addingReportingOverflow(addend)
        if overflowed {
            return addend > 0 ? .max : 0
        }
        return max(sum, 0)
    }

    /// Reserve resources for a VM
    func reserveResources(vcpus: Int, memory: Int64, storage: Int64) throws {
        let check = canAccommodateVM(vcpus: vcpus, memory: memory, storage: storage)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }

        reservedVCPUs = Self.reserving(reservedVCPUs, vcpus)
        reservedMemory = Self.reserving(reservedMemory, memory)
        reservedStorage = Self.reserving(reservedStorage, storage)
        vmCount += 1
    }

    /// Reserve resources for a sandbox: same vCPU/memory pools as VMs, its own
    /// count, no storage.
    func reserveSandboxResources(vcpus: Int, memory: Int64) throws {
        let check = canAccommodateSandbox(vcpus: vcpus, memory: memory)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }

        reservedVCPUs = Self.reserving(reservedVCPUs, vcpus)
        reservedMemory = Self.reserving(reservedMemory, memory)
        sandboxCount += 1
    }

    /// Check whether `bytes` of storage fits, for the objects that draw on the
    /// shared pool without being a VM: snapshot artifacts (issue #426) and
    /// volumes (STR-181).
    ///
    /// Like the sibling checks above, overflow is treated as "does not fit"
    /// rather than trapping the process: `bytes` is caller-influenced (it is
    /// seeded from a sandbox's guest memory, or from a requested volume size),
    /// so a plain `+` here was a remotely reachable crash (issue #826).
    ///
    /// - Parameter subject: What the refusal names, so the operator reads
    ///   "for the volume" rather than a generic overage.
    func canAccommodateStorage(_ bytes: Int64, for subject: String) -> (allowed: Bool, reason: String?) {
        if !isEnabled {
            return (true, nil)
        }
        let (newStorage, storageOverflowed) = reservedStorage.addingReportingOverflow(bytes)
        if storageOverflowed || newStorage > maxStorage {
            let availableGB = Double(availableStorage) / 1024 / 1024 / 1024
            let requestedGB = Double(bytes) / 1024 / 1024 / 1024
            return (
                false,
                "Insufficient storage quota for \(subject): \(String(format: "%.2f", availableGB))GiB available, \(String(format: "%.2f", requestedGB))GiB requested"
            )
        }
        return (true, nil)
    }

    /// Whether one more volume fits, in *bytes and count* (STR-181).
    ///
    /// The count half is skipped entirely when `maxVolumes` is nil, which is the
    /// default and means no count limit — unlike VMs and sandboxes, where the
    /// limit always exists.
    func canAccommodateVolume(size: Int64) -> (allowed: Bool, reason: String?) {
        let storage = canAccommodateStorage(size, for: "the volume")
        guard storage.allowed else { return storage }
        if isEnabled, let maxVolumes, volumeCount >= maxVolumes {
            return (false, "Volume limit reached: \(maxVolumes) volumes allowed")
        }
        return (true, nil)
    }

    /// Reserve storage for a snapshot artifact or a volume resize (issues #426,
    /// #564, STR-181). The add cannot trap; see ``reserving(_:_:)``. `bytes` is
    /// not certain to be positive here — the export path passes an
    /// agent-reported size — which is the other reason the result floors at
    /// zero.
    func reserveStorage(_ bytes: Int64, for subject: String) throws {
        let check = canAccommodateStorage(bytes, for: subject)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }
        reservedStorage = Self.reserving(reservedStorage, bytes)
    }

    /// Reserve one volume's bytes and, when a count limit is set, its slot
    /// (STR-181).
    func reserveVolumeResources(size: Int64) throws {
        let check = canAccommodateVolume(size: size)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }
        reservedStorage = Self.reserving(reservedStorage, size)
        volumeCount += 1
    }
}

// MARK: - Validations

extension ResourceQuota {
    /// The invariants that hold regardless of how much of the quota is in use:
    /// exactly one scope, and positive limits.
    ///
    /// Deliberately *not* "reserved fits within max" (issue #742). The write
    /// paths measure real usage into the reservation counters, and a scope can
    /// legitimately be over its limits — introducing a quota below an existing
    /// tenant's usage is how enforcement starts, and further growth is then
    /// blocked at admission — so such a quota has to stay editable for an
    /// operator to raise, disable, or rename it. Each limit an update *does*
    /// change is guarded against freshly measured usage by the caller.
    func validate() throws {
        // Ensure quota belongs to exactly one entity
        let parentCount = [
            $organization.id != nil,
            $organizationalUnit.id != nil,
            $project.id != nil,
        ].filter { $0 }.count

        if parentCount != 1 {
            throw Abort(
                .badRequest,
                reason: "Resource quota must belong to exactly one entity (organization, folder, or project)")
        }

        // Validate limits are positive
        if maxVCPUs <= 0 || maxMemory <= 0 || maxStorage <= 0 || maxVMs <= 0 || maxSandboxes <= 0 {
            throw Abort(.badRequest, reason: "All resource limits must be positive")
        }

        // `maxVolumes` is optional, so "unset" and "zero" have to stay
        // distinguishable: nil is no limit, and a limit of zero — which would
        // admit nothing at all — is a mistake, not a policy.
        if let maxVolumes, maxVolumes <= 0 {
            throw Abort(.badRequest, reason: "The volume limit must be positive when set")
        }
    }
}

// MARK: - DTOs

struct CreateResourceQuotaRequest: Content, ValidatedRequestBody {
    /// Bounded because it does not stay in the database: a rejection
    /// interpolates it into the `403` body
    /// (`QuotaEnforcementService.rejectionReason`).
    var name: String
    let maxVCPUs: Int
    let maxMemoryGB: Double
    let maxStorageGB: Double
    let maxVMs: Int
    /// Sandbox count limit; defaults to `maxVMs` when omitted.
    let maxSandboxes: Int?
    /// Volume count limit; omitted means **no** count limit, not a default
    /// borrowed from `maxVMs` (STR-181).
    let maxVolumes: Int?
    let maxNetworks: Int?
    var environment: String?
    let isEnabled: Bool?

    mutating func validate() throws {
        name = try Validate.name(name)
        environment = try Validate.name(environment, "environment")
    }
}

struct UpdateResourceQuotaRequest: Content, ValidatedRequestBody {
    var name: String?
    let maxVCPUs: Int?
    let maxMemoryGB: Double?
    let maxStorageGB: Double?
    let maxVMs: Int?
    let maxSandboxes: Int?
    /// The volume count limit (STR-181). Omitted leaves it as it is; **`0`
    /// removes it**.
    ///
    /// A sentinel because this is the one limit that can legitimately be unset,
    /// and Swift's synthesized decoding cannot tell an absent key from an
    /// explicit null — the same wall `SetVolumeIOLimitsRequest` documents. Zero
    /// is free to mean this: a limit of zero would admit no volume at all, so
    /// `validate()` refuses it on the model and nothing can want it.
    let maxVolumes: Int?
    let maxNetworks: Int?
    let isEnabled: Bool?

    mutating func validate() throws {
        name = try Validate.name(name)
    }
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
        /// Null means no volume count limit (STR-181).
        let maxVolumes: Int?
        let maxNetworks: Int
    }

    struct ResourceUsage: Content {
        let reservedVCPUs: Int
        let reservedMemoryGB: Double
        let reservedStorageGB: Double
        let vmCount: Int
        let sandboxCount: Int
        let volumeCount: Int
        let networkCount: Int
    }

    struct ResourceUtilization: Content {
        let cpuPercent: Double
        let memoryPercent: Double
        let storagePercent: Double
        let vmPercent: Double
        let sandboxPercent: Double
        /// Null when no volume count limit is set — not 0%, which would read as
        /// a limit nobody is using.
        let volumePercent: Double?
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
            maxVolumes: quota.maxVolumes,
            maxNetworks: quota.maxNetworks
        )

        self.usage = ResourceUsage(
            reservedVCPUs: quota.reservedVCPUs,
            reservedMemoryGB: Double(quota.reservedMemory) / 1024 / 1024 / 1024,
            reservedStorageGB: Double(quota.reservedStorage) / 1024 / 1024 / 1024,
            vmCount: quota.vmCount,
            sandboxCount: quota.sandboxCount,
            volumeCount: quota.volumeCount,
            networkCount: quota.networkCount
        )

        self.utilization = ResourceUtilization(
            cpuPercent: quota.cpuUtilizationPercent,
            memoryPercent: quota.memoryUtilizationPercent,
            storagePercent: quota.storageUtilizationPercent,
            vmPercent: quota.vmUtilizationPercent,
            sandboxPercent: quota.sandboxUtilizationPercent,
            volumePercent: quota.volumeUtilizationPercent
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
    /// Null means no volume count limit (STR-181).
    let maxVolumes: Int?
    let maxNetworks: Int
}

struct QuotaUsage: Content {
    let vcpus: Int
    let memoryGB: Double
    let storageGB: Double
    let vms: Int
    let sandboxes: Int
    let volumes: Int
    let networks: Int
}

struct QuotaUtilization: Content {
    let cpuPercent: Double
    let memoryPercent: Double
    let storagePercent: Double
    let vmPercent: Double
    let sandboxPercent: Double
    /// Null when no volume count limit is set (STR-181).
    let volumePercent: Double?
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
