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

/// A capacity refusal is permanent for create. Boot and resize wrap the same
/// actionable text in `DependencyPendingError`, because another workload can
/// release the dependency without changing the desired generation.
public struct HostCapacityAdmissionError: ClassifiableError, LocalizedError, Equatable {
    public enum Resource: Sendable, Equatable { case inventory, cpu, memory }

    public let agentName: String
    public let resource: Resource
    public let available: HostReservation
    public let required: HostReservation

    public var failureClassification: FailureClassification { .permanent }

    public var errorDescription: String? {
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

    public init() {}

    public var provisionalReservation: HostReservation {
        claims.values.reduce(HostReservation()) { $0.addingSaturating($1) }
    }

    public mutating func claim(
        _ requested: HostReservation,
        snapshot: HostCapacitySnapshot,
        agentName: String
    ) throws -> HostCapacityClaim? {
        guard requested.cpus > 0 || requested.memoryBytes > 0 else { return nil }
        guard snapshot.inventoryKnown else {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .inventory, available: HostReservation(), required: requested)
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
        return claim
    }

    /// Boot consumes an already-reserved footprint, but it must not start a
    /// process on a host whose raw committed inventory is already impossible.
    public func validateExistingReservation(
        snapshot: HostCapacitySnapshot, agentName: String
    ) throws {
        guard snapshot.inventoryKnown else {
            throw HostCapacityAdmissionError(
                agentName: agentName, resource: .inventory, available: HostReservation(),
                required: HostReservation())
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
        claims.removeValue(forKey: claim.id)
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
            let hotplug = MemoryHotplugPlan.alignedHotplugBytes(spec: spec, architecture: architecture)
            let (sum, overflow) = spec.memoryBytes.addingReportingOverflow(hotplug)
            memory = overflow ? Int64.max : sum
        } else {
            memory = spec.memoryBytes
        }
        return HostReservation(cpus: spec.cpus, memoryBytes: memory)
    }
}
