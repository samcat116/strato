import Foundation
import StratoShared

/// CPU and memory committed on a host. Arithmetic is deliberately saturating:
/// malformed or extreme inventory must make the host look full, never wrap it
/// back into available capacity.
public struct HostReservation: Sendable, Equatable, Hashable {
    public var cpus: Int
    public var memoryBytes: Int64

    public init(cpus: Int = 0, memoryBytes: Int64 = 0) {
        self.cpus = max(0, cpus)
        self.memoryBytes = max(0, memoryBytes)
    }

    public static func positiveDelta(from current: HostReservation, to desired: HostReservation) -> HostReservation {
        HostReservation(
            cpus: desired.cpus > current.cpus ? desired.cpus - current.cpus : 0,
            memoryBytes: desired.memoryBytes > current.memoryBytes ? desired.memoryBytes - current.memoryBytes : 0)
    }

    public func addingSaturating(_ other: HostReservation) -> HostReservation {
        let (cpu, cpuOverflow) = cpus.addingReportingOverflow(other.cpus)
        let (memory, memoryOverflow) = memoryBytes.addingReportingOverflow(other.memoryBytes)
        return HostReservation(
            cpus: cpuOverflow ? Int.max : cpu,
            memoryBytes: memoryOverflow ? Int64.max : memory)
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
                    cpus: max(observed.cpus, durable.cpus),
                    memoryBytes: max(observed.memoryBytes, durable.memoryBytes))
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

    public init(total: HostReservation, reserved: HostReservation, inventoryKnown: Bool = true) {
        self.total = total
        self.reserved = reserved
        self.inventoryKnown = inventoryKnown
    }

    public var available: HostReservation {
        guard inventoryKnown else { return HostReservation() }
        return HostReservation(
            cpus: reserved.cpus >= total.cpus ? 0 : total.cpus - reserved.cpus,
            memoryBytes: reserved.memoryBytes >= total.memoryBytes ? 0 : total.memoryBytes - reserved.memoryBytes)
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
    public enum Resource: Sendable, Equatable { case inventory, cpu, memory }

    public let agentName: String
    public let resource: Resource
    public let available: HostReservation
    public let required: HostReservation
    public let failureClassification: FailureClassification

    public init(
        agentName: String,
        resource: Resource,
        available: HostReservation,
        required: HostReservation,
        failureClassification: FailureClassification = .blocked
    ) {
        self.agentName = agentName
        self.resource = resource
        self.available = available
        self.required = required
        self.failureClassification = failureClassification
    }

    public var errorDescription: String? {
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
    private var claims: [UUID: HostReservation] = [:]
    public private(set) var revision: UInt64 = 0

    public init() {}

    public var provisionalReservation: HostReservation {
        claims.values.reduce(HostReservation()) { $0.addingSaturating($1) }
    }

    public mutating func claim(
        _ requested: HostReservation,
        desiredWorkloadReservation: HostReservation,
        snapshot: HostCapacitySnapshot,
        agentName: String
    ) throws -> HostCapacityClaim? {
        guard requested.cpus > 0 || requested.memoryBytes > 0 else { return nil }
        guard snapshot.inventoryKnown else {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .inventory, available: HostReservation(), required: requested)
        }

        // Capacity released by neighbours can never make this workload fit if
        // its desired post-operation footprint exceeds the physical host. Use
        // the desired footprint directly: adding positive growth to the current
        // reservation would retain old values in dimensions this same resize
        // shrinks, and could make a corrective mixed resize look impossible.
        if desiredWorkloadReservation.cpus > snapshot.total.cpus {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .cpu, available: snapshot.total,
                required: desiredWorkloadReservation, failureClassification: .permanent)
        }
        if desiredWorkloadReservation.memoryBytes > snapshot.total.memoryBytes {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .memory, available: snapshot.total,
                required: desiredWorkloadReservation, failureClassification: .permanent)
        }

        let committedAndProvisional = snapshot.reserved.addingSaturating(provisionalReservation)
        let effective = HostCapacitySnapshot(
            total: snapshot.total, reserved: committedAndProvisional, inventoryKnown: true
        ).available
        guard requested.cpus <= effective.cpus else {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .cpu, available: effective, required: requested)
        }
        guard requested.memoryBytes <= effective.memoryBytes else {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .memory, available: effective, required: requested)
        }

        let claim = HostCapacityClaim(id: UUID(), reservation: requested)
        claims[claim.id] = requested
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
        if currentWorkloadReservation.cpus > snapshot.total.cpus {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .cpu, available: snapshot.total,
                required: currentWorkloadReservation, failureClassification: .permanent)
        }
        if currentWorkloadReservation.memoryBytes > snapshot.total.memoryBytes {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .memory, available: snapshot.total,
                required: currentWorkloadReservation, failureClassification: .permanent)
        }
        let used = snapshot.reserved.addingSaturating(provisionalReservation)
        if used.cpus > snapshot.total.cpus {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .cpu, available: HostReservation(),
                required: HostReservation(cpus: used.cpus - snapshot.total.cpus))
        }
        if used.memoryBytes > snapshot.total.memoryBytes {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .memory, available: HostReservation(),
                required: HostReservation(memoryBytes: used.memoryBytes - snapshot.total.memoryBytes))
        }
    }

    public mutating func release(_ claim: HostCapacityClaim?) {
        guard let claim else { return }
        guard claims.removeValue(forKey: claim.id) != nil else { return }
        revision &+= 1
    }
}

/// Reservation semantics shared by host admission and tests. QEMU reserves the
/// aligned hot-add region already present in its domain; other backends reserve
/// current guest memory only.
public enum VMHostReservation {
    public static func forSpec(
        _ spec: VMSpec, hypervisorType: HypervisorType, architecture: CPUArchitecture
    ) -> HostReservation {
        let memory: Int64
        if hypervisorType == .qemu {
            memory = QEMUMemoryReservation.reservedBytes(
                memoryBytes: spec.memoryBytes,
                maxMemoryBytes: spec.maxMemoryBytes,
                architecture: architecture)
        } else {
            memory = spec.memoryBytes
        }
        return HostReservation(cpus: spec.cpus, memoryBytes: memory)
    }

    /// Reservation carried by the durable manifest. A QEMU entry written by a
    /// current agent records the domain's fixed realized ceiling explicitly.
    /// A legacy entry cannot reconstruct that ceiling after a live resize, so
    /// it keeps the full requested maximum reserved rather than risk releasing
    /// memory the domain still owns.
    public static func forManifestEntry(
        _ entry: VMManifestEntry, architecture: CPUArchitecture
    ) -> HostReservation {
        guard entry.hypervisorType == .qemu else {
            return forSpec(entry.spec, hypervisorType: entry.hypervisorType, architecture: architecture)
        }
        let legacyReservation = max(entry.spec.memoryBytes, entry.spec.maxMemoryBytes)
        let fixedReservation = entry.realizedMemoryReservationBytes ?? legacyReservation
        return HostReservation(
            cpus: entry.spec.cpus,
            memoryBytes: max(entry.spec.memoryBytes, fixedReservation))
    }
}

/// Sandboxes share the host's 1:1 CPU and memory pools with VMs. Keeping this
/// conversion beside the VM version makes create and boot admission use the
/// same reservation semantics as heartbeat accounting.
public enum SandboxHostReservation {
    public static func forSpec(_ spec: SandboxSpec) -> HostReservation {
        HostReservation(cpus: spec.cpus, memoryBytes: spec.memoryBytes)
    }
}
