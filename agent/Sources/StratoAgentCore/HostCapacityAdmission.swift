import Foundation
import StratoShared

/// CPU, memory, and local disk committed on a host. Arithmetic is deliberately saturating:
/// malformed or extreme inventory must make the host look full, never wrap it
/// back into available capacity.
public struct HostReservation: Sendable, Equatable, Hashable {
    public var cpuMicroUnits: Int64
    public var cpus: Int {
        get {
            cpuMicroUnits == Int64.max
                ? Int.max : Int(cpuMicroUnits / 1_000_000 + (cpuMicroUnits % 1_000_000 == 0 ? 0 : 1))
        }
        set { cpuMicroUnits = WorkloadResourceClassPolicy.guaranteed.cpuMicroUnits(cpus: newValue) }
    }
    public var memoryBytes: Int64
    public var diskBytes: Int64

    public init(cpus: Int = 0, memoryBytes: Int64 = 0, diskBytes: Int64 = 0, cpuMicroUnits: Int64? = nil) {
        self.cpuMicroUnits = max(0, cpuMicroUnits ?? WorkloadResourceClassPolicy.guaranteed.cpuMicroUnits(cpus: cpus))
        self.memoryBytes = max(0, memoryBytes)
        self.diskBytes = max(0, diskBytes)
    }

    public static func positiveDelta(from current: HostReservation, to desired: HostReservation) -> HostReservation {
        HostReservation(
            memoryBytes: desired.memoryBytes > current.memoryBytes ? desired.memoryBytes - current.memoryBytes : 0,
            diskBytes: desired.diskBytes > current.diskBytes ? desired.diskBytes - current.diskBytes : 0,
            cpuMicroUnits: desired.cpuMicroUnits > current.cpuMicroUnits
                ? desired.cpuMicroUnits - current.cpuMicroUnits : 0)
    }

    public func addingSaturating(_ other: HostReservation) -> HostReservation {
        let (cpu, cpuOverflow) = cpuMicroUnits.addingReportingOverflow(other.cpuMicroUnits)
        let (memory, memoryOverflow) = memoryBytes.addingReportingOverflow(other.memoryBytes)
        let (disk, diskOverflow) = diskBytes.addingReportingOverflow(other.diskBytes)
        return HostReservation(
            memoryBytes: memoryOverflow ? Int64.max : memory,
            diskBytes: diskOverflow ? Int64.max : disk, cpuMicroUnits: cpuOverflow ? Int64.max : cpu)
    }

    public func subtractingSaturating(_ other: HostReservation) -> HostReservation {
        HostReservation(
            memoryBytes: other.memoryBytes >= memoryBytes ? 0 : memoryBytes - other.memoryBytes,
            diskBytes: other.diskBytes >= diskBytes ? 0 : diskBytes - other.diskBytes,
            cpuMicroUnits: other.cpuMicroUnits >= cpuMicroUnits ? 0 : cpuMicroUnits - other.cpuMicroUnits)
    }
}

/// A backend's committed reservation and, when it can say, the exact workload
/// inventory that produced it. Keeping the two in one value is important for
/// daemon-backed drivers: an independently fetched ID list can race the
/// reservation sweep and make an absent orphan look accounted for when it is
/// not.
public struct HypervisorReservationInventory: Sendable, Equatable {
    public let reservation: HostReservation
    public let workloadIDs: Set<String>?
    /// Exact per-workload reservations when the backend can collect sizing and
    /// membership in the same sweep. This lets admission raise a cached entry
    /// to a newer durable manifest size without discarding other domains from
    /// that cached inventory.
    public let workloadReservations: [String: HostReservation]?

    public init(
        reservation: HostReservation,
        workloadIDs: Set<String>? = nil,
        workloadReservations: [String: HostReservation]? = nil
    ) {
        self.reservation = reservation
        self.workloadReservations = workloadReservations
        self.workloadIDs = workloadReservations.map { Set($0.keys) } ?? workloadIDs
    }

    /// Replaces only owned, bounded raw commitments; unknown or oversized
    /// backend processes retain their full physical reservation.
    public func accountingForAdmittedWorkloads(_ admitted: [String: WorkloadAdmittedReservation]) -> Self {
        guard let exact = workloadReservations else { return self }
        var rawTotal = HostReservation()
        var accountedTotal = HostReservation()
        var accounted: [String: HostReservation] = [:]
        for (id, raw) in exact {
            rawTotal = rawTotal.addingSaturating(raw)
            let commitment: HostReservation
            if let grant = admitted[id], raw.cpus <= grant.grantedCPUs,
                raw.memoryBytes
                    <= WorkloadMemoryReservation(
                        guestBytes: grant.guestCommitmentBytes, backendOverheadBytes: grant.backendOverheadBytes
                    ).effectiveBytes
            {
                commitment = HostReservation(
                    memoryBytes: grant.effectiveMemoryBytes, diskBytes: raw.diskBytes,
                    cpuMicroUnits: grant.cpuMicroUnits)
            } else {
                commitment = raw
            }
            accounted[id] = commitment
            accountedTotal = accountedTotal.addingSaturating(commitment)
        }
        return Self(
            reservation: reservation.subtractingSaturating(rawTotal).addingSaturating(accountedTotal),
            workloadReservations: accounted)
    }

    /// Reconciles durable manifest reservations with the backend inventory.
    /// Exact per-workload sizing takes the larger value in each dimension, so
    /// a cached pre-resize aggregate cannot hide a newer manifest grant. With
    /// membership only, missing workloads are added as before. A backend that
    /// cannot identify its aggregate's members conservatively retains every
    /// durable workload.
    public func includingMissingWorkloads(_ workloads: [String: HostReservation]) -> HostReservation {
        if var reconciled = workloadReservations {
            for (id, durable) in workloads {
                let observed = reconciled[id] ?? HostReservation()
                reconciled[id] = HostReservation(
                    memoryBytes: max(observed.memoryBytes, durable.memoryBytes),
                    diskBytes: max(observed.diskBytes, durable.diskBytes),
                    cpuMicroUnits: max(observed.cpuMicroUnits, durable.cpuMicroUnits))
            }
            return reconciled.values.reduce(HostReservation()) { total, workload in
                total.addingSaturating(workload)
            }
        }
        return workloads.reduce(reservation) { total, workload in
            guard workloadIDs?.contains(workload.key) != true else { return total }
            return total.addingSaturating(workload.value)
        }
    }
}

/// The raw, un-clamped host accounting an admission decision needs.
public struct HostCapacitySnapshot: Sendable, Equatable {
    public let total: HostReservation
    public let reserved: HostReservation
    public let inventoryKnown: Bool
    public let diskInventoryKnown: Bool
    public let hostReservedMemoryBytes: Int64
    public let qemuOverheadBytes: Int64
    public let workloadReservations: [String: HostReservation]

    public var memoryAccounting: HostMemoryAccounting {
        HostMemoryAccounting(
            physicalBytes: total.memoryBytes, hostReservedBytes: hostReservedMemoryBytes,
            workloadEffectiveBytes: reserved.memoryBytes, inventoryKnown: inventoryKnown,
            qemuOverheadBytes: qemuOverheadBytes)
    }

    public init(
        total: HostReservation,
        reserved: HostReservation,
        inventoryKnown: Bool = true,
        diskInventoryKnown: Bool? = nil,
        hostReservedMemoryBytes: Int64 = 0,
        qemuOverheadBytes: Int64 = WorkloadMemoryReservation.defaultQEMUOverheadBytes,
        workloadReservations: [String: HostReservation] = [:]
    ) {
        self.total = total
        self.reserved = reserved
        self.inventoryKnown = inventoryKnown
        self.diskInventoryKnown = diskInventoryKnown ?? inventoryKnown
        self.hostReservedMemoryBytes = max(0, hostReservedMemoryBytes)
        self.qemuOverheadBytes = max(0, qemuOverheadBytes)
        self.workloadReservations = workloadReservations
    }

    public var available: HostReservation {
        return HostReservation(
            memoryBytes: memoryAccounting.remainingAllocatableBytes,
            diskBytes: !diskInventoryKnown || reserved.diskBytes >= total.diskBytes
                ? 0 : total.diskBytes - reserved.diskBytes,
            cpuMicroUnits: !inventoryKnown || reserved.cpuMicroUnits >= total.cpuMicroUnits
                ? 0 : total.cpuMicroUnits - reserved.cpuMicroUnits)
    }
}

/// A successful provisional claim. The owner releases it after the manifest
/// commit or after the operation fails.
public struct HostCapacityClaim: Sendable, Hashable {
    fileprivate let id: UUID
    public let reservation: HostReservation
}

/// A capacity refusal is reported and re-driven at the same generation: a
/// neighbouring workload can release the missing capacity independently.
public struct HostCapacityAdmissionError: ClassifiableError, LocalizedError, Equatable {
    public enum Resource: Sendable, Equatable { case inventory, cpu, memory, disk }

    public let agentName: String
    public let resource: Resource
    public let available: HostReservation
    public let required: HostReservation
    public let failureClassification: FailureClassification
    public let memoryAccounting: HostMemoryAccounting?

    public init(
        agentName: String,
        resource: Resource,
        available: HostReservation,
        required: HostReservation,
        failureClassification: FailureClassification = .blocked,
        memoryAccounting: HostMemoryAccounting? = nil
    ) {
        self.agentName = agentName
        self.resource = resource
        self.available = available
        self.required = required
        self.failureClassification = failureClassification
        self.memoryAccounting = memoryAccounting
    }

    public var errorDescription: String? {
        if resource == .memory, let accounting = memoryAccounting {
            return
                "agent `\(agentName)` refused memory admission: physicalBytes=\(accounting.physicalBytes), hostReservedBytes=\(accounting.hostReservedBytes), workloadEffectiveBytes=\(accounting.workloadEffectiveBytes), remainingAllocatableBytes=\(accounting.remainingAllocatableBytes), requiredEffectiveBytes=\(required.memoryBytes), qemuOverheadBytes=\(accounting.qemuOverheadBytes)"
        }
        if failureClassification == .permanent {
            switch resource {
            case .inventory:
                break
            case .cpu:
                return
                    "agent `\(agentName)` has \(available.cpus) total vCPUs; this workload requires \(required.cpus) vCPUs"
            case .memory:
                return
                    "agent `\(agentName)` has \(Self.byteString(available.memoryBytes)) total memory; this workload requires \(Self.byteString(required.memoryBytes))"
            case .disk:
                return
                    "agent `\(agentName)` has \(Self.byteString(available.diskBytes)) total local disk; this operation requires \(Self.byteString(required.diskBytes))"
            }
        }
        switch resource {
        case .inventory:
            return "agent `\(agentName)` cannot verify its workload inventory; capacity admission is unavailable"
        case .cpu:
            return
                "agent `\(agentName)` has \(available.cpus) vCPUs available; this operation requires \(required.cpus) additional vCPUs"
        case .memory:
            return
                "agent `\(agentName)` has \(Self.byteString(available.memoryBytes)) available; this operation requires \(Self.byteString(required.memoryBytes)) additional memory"
        case .disk:
            return
                "agent `\(agentName)` has \(Self.byteString(available.diskBytes)) local disk available; this operation requires \(Self.byteString(required.diskBytes)) additional disk"
        }
    }

    private static func byteString(_ bytes: Int64) -> String {
        let gib: Int64 = 1024 * 1024 * 1024
        let mib: Int64 = 1024 * 1024
        if bytes % gib == 0 { return "\(bytes / gib) GiB" }
        if bytes % mib == 0 { return "\(bytes / mib) MiB" }
        return "\(bytes) bytes"
    }
}

/// Atomic from the owning `Agent` actor's point of view. Every reconciliation
/// lane can take a stale host snapshot while awaiting backend inventory; claims
/// made from earlier snapshots are added here before a later lane is admitted.
public struct HostCapacityAdmissionLedger: Sendable {
    private struct PendingClaim: Sendable {
        let reservation: HostReservation
        let workloadID: String?
        let baseline: HostReservation
    }
    private var claims: [UUID: PendingClaim] = [:]
    public private(set) var revision: UInt64 = 0

    public init() {}

    public var provisionalReservation: HostReservation {
        claims.values.reduce(HostReservation()) { $0.addingSaturating($1.reservation) }
    }

    /// An exact backend sweep may observe a create/resize before its owning
    /// lane commits the manifest and retires the claim. Charge only the part
    /// not already represented by that workload's observed footprint.
    public func provisionalReservation(excludingObserved workloads: [String: HostReservation]) -> HostReservation {
        claims.values.reduce(HostReservation()) { total, claim in
            let observed = claim.workloadID.flatMap { workloads[$0] } ?? HostReservation()
            let growth = HostReservation.positiveDelta(from: claim.baseline, to: observed)
            let unobserved = claim.reservation.subtractingSaturating(
                HostReservation(memoryBytes: growth.memoryBytes, cpuMicroUnits: growth.cpuMicroUnits))
            return total.addingSaturating(unobserved)
        }
    }

    public mutating func claim(
        _ requested: HostReservation,
        desiredWorkloadReservation: HostReservation,
        snapshot: HostCapacitySnapshot,
        agentName: String,
        workloadID: String? = nil
    ) throws -> HostCapacityClaim? {
        guard requested.cpuMicroUnits > 0 || requested.memoryBytes > 0 || requested.diskBytes > 0 else { return nil }
        guard snapshot.inventoryKnown else {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .inventory, available: HostReservation(), required: requested)
        }

        // Capacity released by neighbours can never make this workload fit if
        // its desired post-operation footprint exceeds the physical host. Use
        // the desired footprint directly: adding positive growth to the current
        // reservation would retain old values in dimensions this same resize
        // shrinks, and could make a corrective mixed resize look impossible.
        if desiredWorkloadReservation.cpuMicroUnits > snapshot.total.cpuMicroUnits {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .cpu, available: snapshot.total,
                required: desiredWorkloadReservation, failureClassification: .permanent)
        }
        if desiredWorkloadReservation.memoryBytes > snapshot.total.memoryBytes {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .memory, available: snapshot.total,
                required: desiredWorkloadReservation, failureClassification: .permanent,
                memoryAccounting: snapshot.memoryAccounting)
        }
        if requested.diskBytes > 0, !snapshot.diskInventoryKnown {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .inventory, available: HostReservation(), required: requested)
        }
        if desiredWorkloadReservation.diskBytes > snapshot.total.diskBytes {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .disk, available: snapshot.total,
                required: desiredWorkloadReservation, failureClassification: .permanent)
        }

        let committedAndProvisional = snapshot.reserved.addingSaturating(
            provisionalReservation(excludingObserved: snapshot.workloadReservations))
        let effective = HostCapacitySnapshot(
            total: snapshot.total, reserved: committedAndProvisional, inventoryKnown: true,
            diskInventoryKnown: true, hostReservedMemoryBytes: snapshot.hostReservedMemoryBytes,
            qemuOverheadBytes: snapshot.qemuOverheadBytes
        ).available
        guard requested.cpuMicroUnits <= effective.cpuMicroUnits else {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .cpu, available: effective, required: requested)
        }
        guard requested.memoryBytes <= effective.memoryBytes else {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .memory, available: effective, required: requested,
                memoryAccounting: HostMemoryAccounting(
                    physicalBytes: snapshot.total.memoryBytes,
                    hostReservedBytes: snapshot.hostReservedMemoryBytes,
                    workloadEffectiveBytes: committedAndProvisional.memoryBytes,
                    qemuOverheadBytes: snapshot.qemuOverheadBytes))
        }
        guard requested.diskBytes <= effective.diskBytes else {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .disk, available: effective, required: requested)
        }

        let claim = HostCapacityClaim(id: UUID(), reservation: requested)
        claims[claim.id] = PendingClaim(
            reservation: requested, workloadID: workloadID,
            baseline: desiredWorkloadReservation.subtractingSaturating(requested))
        revision &+= 1
        return claim
    }

    /// Boot consumes an already-reserved footprint, but it must not start a
    /// process on a host whose raw committed inventory is already impossible.
    public func validateExistingReservation(
        _ currentWorkloadReservation: HostReservation,
        snapshot: HostCapacitySnapshot,
        agentName: String
    ) throws {
        guard snapshot.inventoryKnown else {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .inventory, available: HostReservation(),
                required: HostReservation())
        }
        if currentWorkloadReservation.cpuMicroUnits > snapshot.total.cpuMicroUnits {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .cpu, available: snapshot.total,
                required: currentWorkloadReservation, failureClassification: .permanent)
        }
        if currentWorkloadReservation.memoryBytes > snapshot.total.memoryBytes {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .memory, available: snapshot.total,
                required: currentWorkloadReservation, failureClassification: .permanent,
                memoryAccounting: snapshot.memoryAccounting)
        }
        if currentWorkloadReservation.diskBytes > 0, !snapshot.diskInventoryKnown {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .inventory, available: HostReservation(),
                required: currentWorkloadReservation)
        }
        if currentWorkloadReservation.diskBytes > snapshot.total.diskBytes {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .disk, available: snapshot.total,
                required: currentWorkloadReservation, failureClassification: .permanent)
        }
        let used = snapshot.reserved.addingSaturating(
            provisionalReservation(excludingObserved: snapshot.workloadReservations))
        if used.cpuMicroUnits > snapshot.total.cpuMicroUnits {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .cpu, available: HostReservation(),
                required: HostReservation(cpus: used.cpus - snapshot.total.cpus))
        }
        let memoryBudget = max(
            0, snapshot.total.memoryBytes - min(snapshot.total.memoryBytes, snapshot.hostReservedMemoryBytes))
        if used.memoryBytes > memoryBudget {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .memory, available: HostReservation(),
                required: HostReservation(memoryBytes: used.memoryBytes - memoryBudget),
                memoryAccounting: snapshot.memoryAccounting)
        }
        if used.diskBytes > snapshot.total.diskBytes {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .disk, available: HostReservation(),
                required: HostReservation(diskBytes: used.diskBytes - snapshot.total.diskBytes))
        }
    }

    public mutating func release(_ claim: HostCapacityClaim?) {
        guard let claim else { return }
        guard claims.removeValue(forKey: claim.id) != nil else { return }
        revision &+= 1
    }
}

/// Reservation semantics shared by host admission and tests. QEMU reserves the
/// aligned hot-add region already present in its domain. Every backend adds
/// its process allowance once.
public enum VMHostReservation {
    public static func forSpec(
        _ spec: VMSpec, hypervisorType: HypervisorType, architecture: CPUArchitecture,
        qemuOverheadBytes: Int64 = WorkloadMemoryReservation.defaultQEMUOverheadBytes
    ) -> HostReservation {
        if spec.resourceClass?.policy.kind == .burstable, let admitted = spec.admittedReservation {
            return HostReservation(memoryBytes: admitted.effectiveMemoryBytes, cpuMicroUnits: admitted.cpuMicroUnits)
        }
        let memory = WorkloadMemoryReservation.vm(
            memoryBytes: spec.memoryBytes, maxMemoryBytes: spec.maxMemoryBytes,
            hypervisorType: hypervisorType, architecture: architecture, qemuOverheadBytes: qemuOverheadBytes)
        let policy = spec.resourceClass?.policy ?? .guaranteed
        return HostReservation(
            memoryBytes: policy.memoryReservation(memory).effectiveBytes,
            cpuMicroUnits: policy.cpuMicroUnits(cpus: spec.cpus))
    }

    /// Reservation carried by the durable manifest. A QEMU entry written by a
    /// current agent records the domain's fixed realized ceiling explicitly.
    /// A legacy entry cannot reconstruct that ceiling after a live resize, so
    /// it keeps the full requested maximum reserved rather than risk releasing
    /// memory the domain still owns.
    public static func forManifestEntry(
        _ entry: VMManifestEntry, architecture: CPUArchitecture,
        qemuOverheadBytes: Int64 = WorkloadMemoryReservation.defaultQEMUOverheadBytes
    ) -> HostReservation {
        if entry.spec.resourceClass?.policy.kind == .burstable, entry.spec.admittedReservation != nil {
            return forSpec(
                entry.spec, hypervisorType: entry.hypervisorType, architecture: architecture,
                qemuOverheadBytes: qemuOverheadBytes)
        }
        guard entry.hypervisorType == .qemu else {
            return forSpec(
                entry.spec, hypervisorType: entry.hypervisorType, architecture: architecture,
                qemuOverheadBytes: qemuOverheadBytes)
        }
        let legacyReservation = max(entry.spec.memoryBytes, entry.spec.maxMemoryBytes)
        let fixedReservation = entry.realizedMemoryReservationBytes ?? legacyReservation
        return HostReservation(
            cpus: entry.spec.cpus,
            memoryBytes: WorkloadMemoryReservation(
                guestBytes: max(entry.spec.memoryBytes, fixedReservation),
                backendOverheadBytes: qemuOverheadBytes
            ).effectiveBytes)
    }
}

/// Sandboxes share the host's CPU and effective memory pools with VMs. Keeping this
/// conversion beside the VM version makes create and boot admission use the
/// same reservation semantics as heartbeat accounting.
public enum SandboxHostReservation {
    public static func forManifestEntry(_ entry: VMManifestEntry) -> HostReservation {
        let base =
            entry.sandboxSpec.map(forSpec)
            ?? HostReservation(cpus: entry.spec.cpus, memoryBytes: entry.spec.memoryBytes)
        guard let record = entry.sandboxSuspension else { return base }
        var disk = max(record.checkpointBytes, record.storageReservationBytes ?? 0)
        if [.restoring, .resuming, .resumed].contains(record.phase) {
            disk = max(disk, restorationDiskBytes(record))
        }
        if record.phase == .suspended, let checkpoint = record.checkpoint, checkpoint.hasValidShape,
            checkpoint.sandboxId == record.sandboxId.uuidString, checkpoint.snapshotId == record.snapshotId.uuidString,
            entry.kind == .sandbox, entry.jailerUsed == true, entry.jailUID == record.jailUID,
            entry.sandboxSpec?.memoryBytes == record.spec.memoryBytes,
            entry.sandboxSpec?.cpus == record.spec.cpus
        {
            return HostReservation(diskBytes: disk)
        }
        return base.addingSaturating(HostReservation(diskBytes: disk))
    }

    /// File restore can need both the retained archive and a fresh jail copy.
    public static func restorationDiskBytes(_ record: SandboxSuspensionRecord) -> Int64 {
        let archive = HostReservation(diskBytes: record.checkpointBytes)
        return archive.addingSaturating(archive).diskBytes
    }

    public static func forSpec(_ spec: SandboxSpec) -> HostReservation {
        if spec.resourceClass?.policy.kind == .burstable, let admitted = spec.admittedReservation {
            return HostReservation(memoryBytes: admitted.effectiveMemoryBytes, cpuMicroUnits: admitted.cpuMicroUnits)
        }
        let policy = spec.resourceClass?.policy ?? .guaranteed
        return HostReservation(
            memoryBytes: policy.memoryReservation(.sandbox(memoryBytes: spec.memoryBytes)).effectiveBytes,
            cpuMicroUnits: policy.cpuMicroUnits(cpus: spec.cpus))
    }
}
