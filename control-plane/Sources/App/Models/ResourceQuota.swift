import ControlPlanePostgres
import Foundation
import Vapor

/// Immutable quota state used by admission and hierarchy code that still runs
/// inside a caller-owned Fluent transaction. Persistence is explicit SQL in
/// `LegacyResourceQuotaStore`; no Fluent identity map or dirty tracking leaks
/// across this boundary.
struct ResourceQuota: Content, Equatable, Sendable {
    let id: UUID?
    let name: String
    let organizationID: UUID?
    let organizationalUnitID: UUID?
    let projectID: UUID?
    let maxVCPUs: Int
    let reservedVCPUs: Int
    let maxMemory: Int64
    let reservedMemory: Int64
    let maxStorage: Int64
    let reservedStorage: Int64
    let maxVMs: Int
    let vmCount: Int
    let maxSandboxes: Int
    let sandboxCount: Int
    let maxVolumes: Int?
    let volumeCount: Int
    let maxNetworks: Int
    let networkCount: Int
    let maxLoadBalancers: Int
    let loadBalancerCount: Int
    let isEnabled: Bool
    let environment: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(
        id: UUID? = UUID(),
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
        maxLoadBalancers: Int? = nil,
        environment: String? = nil,
        isEnabled: Bool = true,
        reservedVCPUs: Int = 0,
        reservedMemory: Int64 = 0,
        reservedStorage: Int64 = 0,
        vmCount: Int = 0,
        sandboxCount: Int = 0,
        volumeCount: Int = 0,
        networkCount: Int = 0,
        loadBalancerCount: Int = 0,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.organizationID = organizationID
        self.organizationalUnitID = organizationalUnitID
        self.projectID = projectID
        self.maxVCPUs = maxVCPUs
        self.reservedVCPUs = reservedVCPUs
        self.maxMemory = maxMemory
        self.reservedMemory = reservedMemory
        self.maxStorage = maxStorage
        self.reservedStorage = reservedStorage
        self.maxVMs = maxVMs
        self.vmCount = vmCount
        self.maxSandboxes = maxSandboxes ?? maxVMs
        self.sandboxCount = sandboxCount
        self.maxVolumes = maxVolumes
        self.volumeCount = volumeCount
        self.maxNetworks = maxNetworks
        self.networkCount = networkCount
        self.maxLoadBalancers = maxLoadBalancers ?? maxVMs
        self.loadBalancerCount = loadBalancerCount
        self.environment = environment
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(snapshot: ResourceQuotaSnapshot) {
        self.init(
            id: snapshot.id,
            name: snapshot.name,
            organizationID: snapshot.organizationID,
            organizationalUnitID: snapshot.organizationalUnitID,
            projectID: snapshot.projectID,
            maxVCPUs: snapshot.maxVCPUs,
            maxMemory: snapshot.maxMemory,
            maxStorage: snapshot.maxStorage,
            maxVMs: snapshot.maxVMs,
            maxSandboxes: snapshot.maxSandboxes,
            maxVolumes: snapshot.maxVolumes,
            maxNetworks: snapshot.maxNetworks,
            maxLoadBalancers: snapshot.maxLoadBalancers,
            environment: snapshot.environment,
            isEnabled: snapshot.isEnabled,
            reservedVCPUs: snapshot.reservedVCPUs,
            reservedMemory: snapshot.reservedMemory,
            reservedStorage: snapshot.reservedStorage,
            vmCount: snapshot.vmCount,
            sandboxCount: snapshot.sandboxCount,
            volumeCount: snapshot.volumeCount,
            networkCount: snapshot.networkCount,
            loadBalancerCount: snapshot.loadBalancerCount,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt)
    }

    func requireID() throws -> UUID {
        guard let id else { throw Abort(.internalServerError, reason: "Resource quota has no identifier") }
        return id
    }

    func save(on db: PostgresStoreContext) async throws {
        _ = try await LegacyResourceQuotaStore.upsert(self, on: db)
    }

    static func find(_ id: UUID?, on db: PostgresStoreContext) async throws -> Self? {
        try await LegacyResourceQuotaStore.quota(id: id, on: db)
    }

    func replacingCounters(
        reservedVCPUs: Int? = nil,
        reservedMemory: Int64? = nil,
        reservedStorage: Int64? = nil,
        vmCount: Int? = nil,
        sandboxCount: Int? = nil,
        volumeCount: Int? = nil,
        networkCount: Int? = nil,
        loadBalancerCount: Int? = nil
    ) -> Self {
        Self(
            id: id, name: name,
            organizationID: organizationID,
            organizationalUnitID: organizationalUnitID,
            projectID: projectID,
            maxVCPUs: maxVCPUs, maxMemory: maxMemory,
            maxStorage: maxStorage, maxVMs: maxVMs,
            maxSandboxes: maxSandboxes, maxVolumes: maxVolumes,
            maxNetworks: maxNetworks, maxLoadBalancers: maxLoadBalancers,
            environment: environment, isEnabled: isEnabled,
            reservedVCPUs: reservedVCPUs ?? self.reservedVCPUs,
            reservedMemory: reservedMemory ?? self.reservedMemory,
            reservedStorage: reservedStorage ?? self.reservedStorage,
            vmCount: vmCount ?? self.vmCount,
            sandboxCount: sandboxCount ?? self.sandboxCount,
            volumeCount: volumeCount ?? self.volumeCount,
            networkCount: networkCount ?? self.networkCount,
            loadBalancerCount: loadBalancerCount ?? self.loadBalancerCount,
            createdAt: createdAt, updatedAt: updatedAt)
    }

    func replacingReservations(with usage: QuotaMeasuredUsage) -> Self {
        replacingCounters(
            reservedVCPUs: usage.vcpus,
            reservedMemory: usage.memoryBytes,
            reservedStorage: usage.storageBytes,
            vmCount: usage.vmCount,
            sandboxCount: usage.sandboxCount,
            volumeCount: usage.volumeCount,
            networkCount: usage.networkCount,
            loadBalancerCount: usage.loadBalancerCount)
    }

    func withEnabled(_ isEnabled: Bool) -> Self {
        replacingConfiguration(isEnabled: isEnabled)
    }

    func withMaxSandboxes(_ maxSandboxes: Int) -> Self {
        replacingConfiguration(maxSandboxes: maxSandboxes)
    }

    func withMaxNetworks(_ maxNetworks: Int) -> Self {
        replacingConfiguration(maxNetworks: maxNetworks)
    }

    func withMaxVolumes(_ maxVolumes: Int?) -> Self {
        Self(
            id: id, name: name,
            organizationID: organizationID,
            organizationalUnitID: organizationalUnitID,
            projectID: projectID,
            maxVCPUs: maxVCPUs, maxMemory: maxMemory,
            maxStorage: maxStorage, maxVMs: maxVMs,
            maxSandboxes: maxSandboxes, maxVolumes: maxVolumes,
            maxNetworks: maxNetworks, maxLoadBalancers: maxLoadBalancers,
            environment: environment, isEnabled: isEnabled,
            reservedVCPUs: reservedVCPUs, reservedMemory: reservedMemory,
            reservedStorage: reservedStorage, vmCount: vmCount,
            sandboxCount: sandboxCount, volumeCount: volumeCount,
            networkCount: networkCount, loadBalancerCount: loadBalancerCount,
            createdAt: createdAt, updatedAt: updatedAt)
    }

    private func replacingConfiguration(
        maxSandboxes: Int? = nil,
        maxNetworks: Int? = nil,
        isEnabled: Bool? = nil
    ) -> Self {
        Self(
            id: id, name: name,
            organizationID: organizationID,
            organizationalUnitID: organizationalUnitID,
            projectID: projectID,
            maxVCPUs: maxVCPUs, maxMemory: maxMemory,
            maxStorage: maxStorage, maxVMs: maxVMs,
            maxSandboxes: maxSandboxes ?? self.maxSandboxes,
            maxVolumes: maxVolumes,
            maxNetworks: maxNetworks ?? self.maxNetworks,
            maxLoadBalancers: maxLoadBalancers,
            environment: environment, isEnabled: isEnabled ?? self.isEnabled,
            reservedVCPUs: reservedVCPUs, reservedMemory: reservedMemory,
            reservedStorage: reservedStorage, vmCount: vmCount,
            sandboxCount: sandboxCount, volumeCount: volumeCount,
            networkCount: networkCount, loadBalancerCount: loadBalancerCount,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}

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
    func calculateActualUsage(on db: PostgresStoreContext) async throws -> QuotaUsage {
        try await QuotaUsageAggregator.measure(quota: self, on: db).asQuotaUsage
    }

    /// Total sandbox-snapshot storage within this quota's scope (issue #426).
    func sandboxSnapshotStorageInScope(on db: PostgresStoreContext) async throws -> Int64 {
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

    var loadBalancerUtilizationPercent: Double {
        guard maxLoadBalancers > 0 else { return 0 }
        return Double(loadBalancerCount) / Double(maxLoadBalancers) * 100
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
    func applyingVMResize(vcpuDelta: Int, memoryDelta: Int64) throws -> Self {
        let check = canAccommodateVMResize(vcpuDelta: vcpuDelta, memoryDelta: memoryDelta)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }

        return replacingCounters(
            reservedVCPUs: max(reservedVCPUs + vcpuDelta, 0),
            reservedMemory: max(reservedMemory + memoryDelta, 0))
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
    func reservingResources(vcpus: Int, memory: Int64, storage: Int64) throws -> Self {
        let check = canAccommodateVM(vcpus: vcpus, memory: memory, storage: storage)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }

        return replacingCounters(
            reservedVCPUs: Self.reserving(reservedVCPUs, vcpus),
            reservedMemory: Self.reserving(reservedMemory, memory),
            reservedStorage: Self.reserving(reservedStorage, storage),
            vmCount: Self.reserving(vmCount, 1))
    }

    /// Reserve resources for a sandbox: same vCPU/memory pools as VMs, its own
    /// count, no storage.
    func reservingSandboxResources(vcpus: Int, memory: Int64) throws -> Self {
        let check = canAccommodateSandbox(vcpus: vcpus, memory: memory)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }

        return replacingCounters(
            reservedVCPUs: Self.reserving(reservedVCPUs, vcpus),
            reservedMemory: Self.reserving(reservedMemory, memory),
            sandboxCount: Self.reserving(sandboxCount, 1))
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

    /// Whether `count` more project-wide logical networks fit (STR-236).
    /// A batch is used when a project moves into a new quota hierarchy; a
    /// normal network create passes one.
    func canAccommodateNetworks(_ count: Int = 1) -> (allowed: Bool, reason: String?) {
        if !isEnabled || count <= 0 {
            return (true, nil)
        }
        let (newCount, overflowed) = networkCount.addingReportingOverflow(count)
        if overflowed || newCount > maxNetworks {
            return (false, "Network limit reached: \(maxNetworks) networks allowed")
        }
        return (true, nil)
    }

    /// Whether `count` more project-wide load balancers fit (STR-28).
    func canAccommodateLoadBalancers(_ count: Int = 1) -> (allowed: Bool, reason: String?) {
        if !isEnabled || count <= 0 { return (true, nil) }
        let (newCount, overflowed) = loadBalancerCount.addingReportingOverflow(count)
        if overflowed || newCount > maxLoadBalancers {
            return (false, "Load balancer limit reached: \(maxLoadBalancers) load balancers allowed")
        }
        return (true, nil)
    }

    /// Reserve storage for a snapshot artifact or a volume resize (issues #426,
    /// #564, STR-181). The add cannot trap; see ``reserving(_:_:)``. `bytes` is
    /// not certain to be positive here — the export path passes an
    /// agent-reported size — which is the other reason the result floors at
    /// zero.
    func reservingStorage(_ bytes: Int64, for subject: String) throws -> Self {
        let check = canAccommodateStorage(bytes, for: subject)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }
        return replacingCounters(reservedStorage: Self.reserving(reservedStorage, bytes))
    }

    /// Reserve one volume's bytes and, when a count limit is set, its slot
    /// (STR-181).
    func reservingVolumeResources(size: Int64) throws -> Self {
        let check = canAccommodateVolume(size: size)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }
        return replacingCounters(
            reservedStorage: Self.reserving(reservedStorage, size),
            volumeCount: Self.reserving(volumeCount, 1))
    }

    /// Reserve project-wide logical-network slots (STR-236).
    func reservingNetworkResources(count: Int = 1) throws -> Self {
        guard count > 0 else { return self }
        let check = canAccommodateNetworks(count)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }
        return replacingCounters(networkCount: Self.reserving(networkCount, count))
    }

    func reservingLoadBalancerResources(count: Int = 1) throws -> Self {
        guard count > 0 else { return self }
        let check = canAccommodateLoadBalancers(count)
        if !check.allowed {
            throw Abort(.forbidden, reason: check.reason ?? "Quota exceeded")
        }
        return replacingCounters(loadBalancerCount: Self.reserving(loadBalancerCount, count))
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
            organizationID != nil,
            organizationalUnitID != nil,
            projectID != nil,
        ].filter { $0 }.count

        if parentCount != 1 {
            throw Abort(
                .badRequest,
                reason: "Resource quota must belong to exactly one entity (organization, folder, or project)")
        }

        // Validate limits are positive
        if maxVCPUs <= 0 || maxMemory <= 0 || maxStorage <= 0 || maxVMs <= 0 || maxSandboxes <= 0
            || maxNetworks <= 0 || maxLoadBalancers <= 0
        {
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
    /// Project-wide network limit. Must be omitted when `environment` is set.
    let maxNetworks: Int?
    /// Project-wide native load-balancer limit; defaults to `maxVMs`.
    let maxLoadBalancers: Int?
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
    /// Project-wide network limit. Environment-scoped quotas reject this field.
    let maxNetworks: Int?
    /// Project-wide load-balancer limit. Environment-scoped quotas reject it.
    let maxLoadBalancers: Int?
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
        let maxLoadBalancers: Int
    }

    struct ResourceUsage: Content {
        let reservedVCPUs: Int
        let reservedMemoryGB: Double
        let reservedStorageGB: Double
        let vmCount: Int
        let sandboxCount: Int
        let volumeCount: Int
        let networkCount: Int
        let loadBalancerCount: Int
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
        let loadBalancerPercent: Double
    }

    init(from quota: ResourceQuota) {
        self.id = quota.id
        self.name = quota.name

        // Determine entity type and ID
        if let orgId = quota.organizationID {
            self.entityType = "organization"
            self.entityId = orgId
        } else if let ouId = quota.organizationalUnitID {
            self.entityType = "ou"
            self.entityId = ouId
        } else if let projId = quota.projectID {
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
            maxNetworks: quota.maxNetworks,
            maxLoadBalancers: quota.maxLoadBalancers
        )

        self.usage = ResourceUsage(
            reservedVCPUs: quota.reservedVCPUs,
            reservedMemoryGB: Double(quota.reservedMemory) / 1024 / 1024 / 1024,
            reservedStorageGB: Double(quota.reservedStorage) / 1024 / 1024 / 1024,
            vmCount: quota.vmCount,
            sandboxCount: quota.sandboxCount,
            volumeCount: quota.volumeCount,
            networkCount: quota.networkCount,
            loadBalancerCount: quota.loadBalancerCount
        )

        self.utilization = ResourceUtilization(
            cpuPercent: quota.cpuUtilizationPercent,
            memoryPercent: quota.memoryUtilizationPercent,
            storagePercent: quota.storageUtilizationPercent,
            vmPercent: quota.vmUtilizationPercent,
            sandboxPercent: quota.sandboxUtilizationPercent,
            volumePercent: quota.volumeUtilizationPercent,
            loadBalancerPercent: quota.loadBalancerUtilizationPercent
        )

        self.createdAt = quota.createdAt
    }

    init(from quota: ResourceQuotaSnapshot) {
        self.id = quota.id
        self.name = quota.name
        if let id = quota.organizationID {
            entityType = "organization"; entityId = id
        } else if let id = quota.organizationalUnitID {
            entityType = "ou"; entityId = id
        } else if let id = quota.projectID {
            entityType = "project"; entityId = id
        } else {
            entityType = "unknown"; entityId = UUID()
        }
        environment = quota.environment
        isEnabled = quota.isEnabled
        limits = ResourceLimits(
            maxVCPUs: quota.maxVCPUs,
            maxMemoryGB: quota.maxMemory.bytesToGB,
            maxStorageGB: quota.maxStorage.bytesToGB,
            maxVMs: quota.maxVMs,
            maxSandboxes: quota.maxSandboxes,
            maxVolumes: quota.maxVolumes,
            maxNetworks: quota.maxNetworks,
            maxLoadBalancers: quota.maxLoadBalancers
        )
        usage = ResourceUsage(
            reservedVCPUs: quota.reservedVCPUs,
            reservedMemoryGB: quota.reservedMemory.bytesToGB,
            reservedStorageGB: quota.reservedStorage.bytesToGB,
            vmCount: quota.vmCount,
            sandboxCount: quota.sandboxCount,
            volumeCount: quota.volumeCount,
            networkCount: quota.networkCount,
            loadBalancerCount: quota.loadBalancerCount
        )
        utilization = ResourceUtilization(
            cpuPercent: quota.maxVCPUs > 0 ? Double(quota.reservedVCPUs) / Double(quota.maxVCPUs) * 100 : 0,
            memoryPercent: quota.maxMemory > 0 ? Double(quota.reservedMemory) / Double(quota.maxMemory) * 100 : 0,
            storagePercent: quota.maxStorage > 0 ? Double(quota.reservedStorage) / Double(quota.maxStorage) * 100 : 0,
            vmPercent: quota.maxVMs > 0 ? Double(quota.vmCount) / Double(quota.maxVMs) * 100 : 0,
            sandboxPercent: quota.maxSandboxes > 0 ? Double(quota.sandboxCount) / Double(quota.maxSandboxes) * 100 : 0,
            volumePercent: quota.maxVolumes.flatMap { $0 > 0 ? Double(quota.volumeCount) / Double($0) * 100 : nil },
            loadBalancerPercent: quota.maxLoadBalancers > 0 ? Double(quota.loadBalancerCount) / Double(quota.maxLoadBalancers) * 100 : 0
        )
        createdAt = quota.createdAt
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
    let maxLoadBalancers: Int
}

struct QuotaUsage: Content {
    let vcpus: Int
    let memoryGB: Double
    let storageGB: Double
    let vms: Int
    let sandboxes: Int
    let volumes: Int
    let networks: Int
    let loadBalancers: Int

    init(
        vcpus: Int, memoryGB: Double, storageGB: Double, vms: Int,
        sandboxes: Int, volumes: Int, networks: Int, loadBalancers: Int = 0
    ) {
        self.vcpus = vcpus
        self.memoryGB = memoryGB
        self.storageGB = storageGB
        self.vms = vms
        self.sandboxes = sandboxes
        self.volumes = volumes
        self.networks = networks
        self.loadBalancers = loadBalancers
    }
}

struct QuotaUtilization: Content {
    let cpuPercent: Double
    let memoryPercent: Double
    let storagePercent: Double
    let vmPercent: Double
    let sandboxPercent: Double
    /// Null when no volume count limit is set (STR-181).
    let volumePercent: Double?
    let loadBalancerPercent: Double
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
