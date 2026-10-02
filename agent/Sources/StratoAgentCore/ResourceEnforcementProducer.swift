import Foundation
import StratoShared

/// Agent-local success bindings. These reset on restart and cannot be created
/// from manifest targets or telemetry alone.
public struct ResourceEnforcementProducer: Sendable {
    public struct Key: Hashable, Sendable {
        public let kind: WorkloadKind
        public let id: UUID
        public init(kind: WorkloadKind, id: UUID) {
            self.kind = kind
            self.id = id
        }
    }
    public struct Application: Equatable, Sendable {
        public let key: Key
        public let generation: Int64
        public let resourceClass: WorkloadResourceClassSnapshot
        public let backend: WorkloadResourceClassBackend
        public let reservation: WorkloadAdmittedReservation
        public let guestBytes: Int64
        public let cpuCount: Int
        public init(
            key: Key, generation: Int64, resourceClass: WorkloadResourceClassSnapshot,
            backend: WorkloadResourceClassBackend, reservation: WorkloadAdmittedReservation, guestBytes: Int64,
            cpuCount: Int? = nil
        ) {
            self.key = key
            self.generation = generation
            self.resourceClass = resourceClass
            self.backend = backend
            self.reservation = reservation
            self.guestBytes = guestBytes
            self.cpuCount = cpuCount ?? reservation.grantedCPUs
        }
    }
    public struct Capture: Sendable {
        fileprivate let revision: UInt64
        public let applications: [Key: Application]
    }
    public let agentBootID: UUID
    public private(set) var applications: [Key: Application] = [:]
    private var attempts: [Key: Int64] = [:]
    private var revision: UInt64 = 0
    private var sequence: Int64 = 0
    public init(agentBootID: UUID = UUID()) { self.agentBootID = agentBootID }

    public mutating func begin(_ key: Key, generation: Int64) {
        guard generation >= 0, generation >= (attempts[key] ?? -1) else { return }
        attempts[key] = generation
        applications.removeValue(forKey: key)
        revision &+= 1
    }
    public mutating func succeeded(_ application: Application) {
        guard attempts[application.key] == application.generation else { return }
        applications[application.key] = application
        revision &+= 1
    }
    /// A settled running observation is necessary even when controls and
    /// accounting match; stale errors and progress cannot authorize claims.
    public static func canAcknowledge(_ record: ObservedVMState, application: Application) -> Bool {
        application.key.kind == .vm && record.vmId == application.key.id
            && record.observedGeneration == application.generation && record.status == .running
            && record.convergencePhase == nil && record.lastError == nil
            && record.failedGeneration == nil && record.failureClassification == nil
    }

    public static func canAcknowledge(_ record: ObservedSandboxState, application: Application) -> Bool {
        application.key.kind == .sandbox && record.sandboxId == application.key.id
            && record.observedGeneration == application.generation && record.status == .running
            && record.convergencePhase == nil && record.lastError == nil
            && record.failedGeneration == nil && record.failureClassification == nil
    }

    public func capture() -> Capture { Capture(revision: revision, applications: applications) }

    /// The caller fences manifest identity as well as both raw accounting
    /// sweeps. The net resources MUST be computed from `after`, not a cache.
    public mutating func finish(
        _ capture: Capture, before: HostCapacitySnapshot, after: HostCapacitySnapshot,
        ledgerRevisionBefore: UInt64, ledgerRevisionAfter: UInt64, inventoryStable: Bool,
        evidence: [Key: WorkloadResourceLimitsEvidence], sampledAt: Date, pageSize: Int64
    ) -> ResourceEnforcementSnapshot? {
        guard capture.revision == revision, before == after,
            ledgerRevisionBefore == ledgerRevisionAfter, inventoryStable,
            Set(capture.applications.keys.map(\.id)).count == capture.applications.count, sequence < Int64.max
        else { return nil }
        let complete = after.inventoryKnown && after.diskInventoryKnown
        var acknowledgements: [WorkloadEnforcementAcknowledgement] = []
        if complete {
            for application in capture.applications.values {
                guard
                    let acknowledgement = Self.acknowledgement(
                        application, accounting: after, evidence: evidence[application.key], pageSize: pageSize)
                else { continue }
                acknowledgements.append(acknowledgement)
            }
        }
        acknowledgements.sort {
            ($0.kind.rawValue, $0.workloadId.uuidString) < ($1.kind.rawValue, $1.workloadId.uuidString)
        }
        let result = ResourceEnforcementSnapshot(
            agentBootID: agentBootID, sequence: sequence, sampledAt: sampledAt,
            inventoryComplete: complete, acknowledgements: acknowledgements)
        sequence += 1
        return result
    }
    /// A failed coherence fence is explicit unknown, not a legacy report.
    /// The caller pairs this with zero allocatable capacity.
    public mutating func incompleteSnapshot(sampledAt: Date) -> ResourceEnforcementSnapshot? {
        guard sequence < Int64.max else { return nil }
        let result = ResourceEnforcementSnapshot(
            agentBootID: agentBootID, sequence: sequence,
            sampledAt: sampledAt, inventoryComplete: false, acknowledgements: [])
        sequence += 1
        return result
    }

    private static func acknowledgement(
        _ application: Application, accounting: HostCapacitySnapshot,
        evidence: WorkloadResourceLimitsEvidence?, pageSize: Int64
    ) -> WorkloadEnforcementAcknowledgement? {
        guard application.generation >= 0, application.resourceClass.policy.kind == .burstable,
            (application.key.kind == .vm && application.backend == .qemuVM)
                || (application.key.kind == .sandbox && application.backend == .jailedFirecrackerSandbox),
            application.cpuCount > 0, application.cpuCount <= application.reservation.grantedCPUs,
            application.guestBytes > 0, application.reservation.guestCommitmentBytes >= application.guestBytes,
            let accounted = accounting.workloadReservations[application.key.id.uuidString],
            accounted.cpuMicroUnits == application.reservation.cpuMicroUnits,
            accounted.memoryBytes == application.reservation.effectiveMemoryBytes,
            let desired = try? application.resourceClass.policy.runtimeLimits(
                guestBytes: application.guestBytes,
                backendOverheadBytes: application.reservation.backendOverheadBytes),
            let target = try? desired.aligned(pageSizeBytes: pageSize), let evidence,
            evidence.desired == desired, evidence.alignedTarget == target,
            evidence.appliedMemoryHighBytes.value == target.memoryHighBytes,
            evidence.appliedMemoryMaxBytes.value == target.memoryMaxBytes,
            evidence.appliedCPUWeight.value == Int64(target.cpuWeight),
            evidence.memoryHighUnlimited.value == false, evidence.memoryMaxUnlimited.value == false,
            evidence.cpuQuotaUnlimited.value == true, evidence.ownershipVerified.value == true,
            evidence.enforcementAcknowledged.value == true
        else { return nil }
        return WorkloadEnforcementAcknowledgement(
            kind: application.key.kind, workloadId: application.key.id,
            appliedGeneration: application.generation, resourceClass: application.resourceClass,
            backend: application.backend, accountedReservation: application.reservation,
            runtimeGuestBytes: application.guestBytes, pageSizeBytes: pageSize, desiredLimits: desired,
            appliedLimits: target, cpuQuotaUnlimited: true, ownershipVerified: true)
    }
}
