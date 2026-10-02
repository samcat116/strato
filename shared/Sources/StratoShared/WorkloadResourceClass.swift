import Foundation

public enum WorkloadResourceClassKind: String, Codable, Sendable, CaseIterable {
    case guaranteed
    case burstable
}

public enum WorkloadHardLimitPolicy: String, Codable, Sendable {
    case guestAndBackend
}

public enum WorkloadResourceClassError: String, Error, Sendable {
    case invalidPolicy
    case invalidIdentity
    case invalidRuntimeLimit
    case enforcementUnavailable
}

/// Bounds are configuration limits, not recommendations for safe overcommit.
public struct WorkloadResourceClassPolicy: Codable, Sendable, Equatable {
    public let kind: WorkloadResourceClassKind
    public let cpuAllocationRatio: Double
    public let memoryAllocationRatio: Double
    public let cpuWeight: Int
    public let memoryHighPercent: Int
    public let hardLimitPolicy: WorkloadHardLimitPolicy
    public let maxCPUPressure10: Double
    public let maxMemoryPressure10: Double
    public let maxTelemetryAgeSeconds: Int

    public init(
        kind: WorkloadResourceClassKind, cpuAllocationRatio: Double = 1,
        memoryAllocationRatio: Double = 1, cpuWeight: Int = 100,
        memoryHighPercent: Int = 100, hardLimitPolicy: WorkloadHardLimitPolicy = .guestAndBackend,
        maxCPUPressure10: Double = 10, maxMemoryPressure10: Double = 5,
        maxTelemetryAgeSeconds: Int = 60
    ) throws {
        guard cpuAllocationRatio.isFinite, (1...64).contains(cpuAllocationRatio),
            memoryAllocationRatio.isFinite, (1...16).contains(memoryAllocationRatio),
            (1...10000).contains(cpuWeight),
            maxCPUPressure10.isFinite, (0...100).contains(maxCPUPressure10),
            maxMemoryPressure10.isFinite, (0...100).contains(maxMemoryPressure10),
            (15...300).contains(maxTelemetryAgeSeconds)
        else { throw WorkloadResourceClassError.invalidPolicy }
        switch kind {
        case .guaranteed:
            guard cpuAllocationRatio == 1, memoryAllocationRatio == 1,
                cpuWeight == 100, memoryHighPercent == 100,
                maxCPUPressure10 == 10, maxMemoryPressure10 == 5, maxTelemetryAgeSeconds == 60
            else { throw WorkloadResourceClassError.invalidPolicy }
        case .burstable:
            guard (1...99).contains(memoryHighPercent) else { throw WorkloadResourceClassError.invalidPolicy }
        }
        self.kind = kind
        self.cpuAllocationRatio = cpuAllocationRatio
        self.memoryAllocationRatio = memoryAllocationRatio
        self.cpuWeight = cpuWeight
        self.memoryHighPercent = memoryHighPercent
        self.hardLimitPolicy = hardLimitPolicy
        self.maxCPUPressure10 = maxCPUPressure10
        self.maxMemoryPressure10 = maxMemoryPressure10
        self.maxTelemetryAgeSeconds = maxTelemetryAgeSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case kind, cpuAllocationRatio, memoryAllocationRatio, cpuWeight, memoryHighPercent, hardLimitPolicy
        case maxCPUPressure10, maxMemoryPressure10, maxTelemetryAgeSeconds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: c.decode(WorkloadResourceClassKind.self, forKey: .kind),
            cpuAllocationRatio: c.decode(Double.self, forKey: .cpuAllocationRatio),
            memoryAllocationRatio: c.decode(Double.self, forKey: .memoryAllocationRatio),
            cpuWeight: c.decode(Int.self, forKey: .cpuWeight),
            memoryHighPercent: c.decode(Int.self, forKey: .memoryHighPercent),
            hardLimitPolicy: c.decode(WorkloadHardLimitPolicy.self, forKey: .hardLimitPolicy),
            maxCPUPressure10: c.decode(Double.self, forKey: .maxCPUPressure10),
            maxMemoryPressure10: c.decode(Double.self, forKey: .maxMemoryPressure10),
            maxTelemetryAgeSeconds: c.decode(Int.self, forKey: .maxTelemetryAgeSeconds))
    }

    public static let guaranteed = try! Self(kind: .guaranteed)
    public static let burstable = try! Self(kind: .burstable, cpuAllocationRatio: 4, memoryHighPercent: 80)

    /// CPU micro-units retain fractional commitment across workloads.
    public func cpuMicroUnits(cpus: Int) -> Int64 {
        Self.ceilingSaturating(Double(max(0, cpus)) * 1_000_000 / cpuAllocationRatio)
    }

    public func memoryReservation(_ raw: WorkloadMemoryReservation) -> WorkloadMemoryReservation {
        // Preserve guaranteed Int64 operands without a lossy floating-point round trip.
        guard kind == .burstable else { return raw }
        return WorkloadMemoryReservation(
            guestBytes: Self.ceilingSaturating(
                (raw.guestBytes > 9_007_199_254_740_992 ? Double(raw.guestBytes).nextUp : Double(raw.guestBytes))
                    / memoryAllocationRatio),
            backendOverheadBytes: raw.backendOverheadBytes)
    }

    private static func ceilingSaturating(_ value: Double) -> Int64 {
        guard value.isFinite, value < Double(Int64.max) else { return .max }
        return Int64(value.rounded(.up))
    }

    /// Runtime denominator is current guest grant, not the placement hotplug commitment.
    public func runtimeLimits(guestBytes: Int64, backendOverheadBytes: Int64) throws -> WorkloadRuntimeLimits {
        guard guestBytes > 0, backendOverheadBytes >= 0 else {
            throw WorkloadResourceClassError.invalidRuntimeLimit
        }
        let (maximum, overflow) = guestBytes.addingReportingOverflow(backendOverheadBytes)
        guard !overflow else { throw WorkloadResourceClassError.invalidRuntimeLimit }
        let percent = Int64(memoryHighPercent)
        let guestHigh = (guestBytes / 100) * percent + ((guestBytes % 100) * percent) / 100
        let high = guestHigh + backendOverheadBytes
        guard kind == .guaranteed || (high > 0 && high < maximum) else {
            throw WorkloadResourceClassError.invalidRuntimeLimit
        }
        return WorkloadRuntimeLimits(memoryHighBytes: high, memoryMaxBytes: maximum, cpuWeight: cpuWeight)
    }

    /// An unavailable or stale required signal cannot be treated as healthy zero pressure.
    public func admissionRefusal(telemetry: HostResourceTelemetry?, now: Date) -> String? {
        guard kind == .burstable else { return nil }
        guard let telemetry, telemetry.sampledAt <= now,
            now.timeIntervalSince(telemetry.sampledAt) <= Double(maxTelemetryAgeSeconds)
        else { return "burstable admission requires fresh host pressure telemetry" }
        guard telemetry.cpuPressure.availability == .available,
            telemetry.memoryPressure.availability == .available,
            let cpu = telemetry.cpuPressure.some?.average10,
            let memory = telemetry.memoryPressure.some?.average10,
            cpu.isFinite, memory.isFinite, cpu >= 0, memory >= 0
        else { return "burstable admission requires available CPU and memory PSI" }
        guard cpu <= maxCPUPressure10 else { return "CPU PSI exceeds the resource class admission gate" }
        guard memory <= maxMemoryPressure10 else { return "memory PSI exceeds the resource class admission gate" }
        return nil
    }
}

public struct WorkloadRuntimeLimits: Codable, Sendable, Equatable {
    /// Kernel memory counters use base pages. Both drivers must normalize before
    /// applying or comparing readback; libvirt then expresses these exact pages in KiB.
    public func aligned(pageSizeBytes: Int64) throws -> Self {
        guard pageSizeBytes >= 1024, pageSizeBytes & (pageSizeBytes - 1) == 0,
            memoryHighBytes > 0, memoryHighBytes < memoryMaxBytes
        else {
            throw WorkloadResourceClassError.invalidRuntimeLimit
        }
        let high = (memoryHighBytes / pageSizeBytes) * pageSizeBytes
        let remainder = memoryMaxBytes % pageSizeBytes
        let (maximum, overflow) = memoryMaxBytes.addingReportingOverflow(
            remainder == 0 ? 0 : pageSizeBytes - remainder)
        guard !overflow, high > 0, high < maximum else {
            throw WorkloadResourceClassError.invalidRuntimeLimit
        }
        return Self(memoryHighBytes: high, memoryMaxBytes: maximum, cpuWeight: cpuWeight)
    }

    public let memoryHighBytes: Int64
    public let memoryMaxBytes: Int64
    public let cpuWeight: Int
}

/// Identity is the compound (siteID, classID); built-in class IDs are stable across sites.
public struct WorkloadResourceClassReference: Codable, Sendable, Equatable {
    public let siteID: UUID
    public let classID: UUID

    public init(siteID: UUID, classID: UUID) {
        self.siteID = siteID
        self.classID = classID
    }
}

/// Immutable admitted policy. Encoding flattens policy and identity into one object.
public struct WorkloadResourceClassSnapshot: Codable, Sendable, Equatable {
    public static let guaranteedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let burstableID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    public let classID: UUID
    public let siteID: UUID
    public let revision: Int64
    public let policy: WorkloadResourceClassPolicy

    public init(classID: UUID, siteID: UUID, revision: Int64, policy: WorkloadResourceClassPolicy) throws {
        guard revision > 0,
            (policy.kind == .guaranteed && classID == Self.guaranteedID && revision == 1)
                || (policy.kind == .burstable && classID == Self.burstableID)
        else { throw WorkloadResourceClassError.invalidIdentity }
        self.classID = classID
        self.siteID = siteID
        self.revision = revision
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey { case classID, siteID, revision }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            classID: c.decode(UUID.self, forKey: .classID), siteID: c.decode(UUID.self, forKey: .siteID),
            revision: c.decode(Int64.self, forKey: .revision), policy: WorkloadResourceClassPolicy(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try policy.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(classID, forKey: .classID)
        try c.encode(siteID, forKey: .siteID)
        try c.encode(revision, forKey: .revision)
    }
}

/// A durable physical commitment. Growth prices only newly admitted guest/CPU
/// units; catalog edits cannot reprice the previous grant.
public struct WorkloadAdmittedReservation: Codable, Sendable, Equatable {
    public let grantedCPUs: Int
    public let guestCommitmentBytes: Int64
    public let cpuMicroUnits: Int64
    public let discountedGuestBytes: Int64
    public let backendOverheadBytes: Int64
    public var effectiveMemoryBytes: Int64 {
        WorkloadMemoryReservation(guestBytes: discountedGuestBytes, backendOverheadBytes: backendOverheadBytes)
            .effectiveBytes
    }

    public init(cpus: Int, memory: WorkloadMemoryReservation, policy: WorkloadResourceClassPolicy) {
        self.grantedCPUs = max(0, cpus)
        self.guestCommitmentBytes = memory.guestBytes
        self.cpuMicroUnits = policy.cpuMicroUnits(cpus: cpus)
        self.discountedGuestBytes = policy.memoryReservation(memory).guestBytes
        self.backendOverheadBytes = memory.backendOverheadBytes
    }

    private init(cpus: Int, guest: Int64, cpuMicroUnits: Int64, discountedGuest: Int64, overhead: Int64) {
        grantedCPUs = cpus
        guestCommitmentBytes = guest
        self.cpuMicroUnits = cpuMicroUnits
        discountedGuestBytes = discountedGuest
        backendOverheadBytes = overhead
    }

    public func growing(cpus: Int, memory: WorkloadMemoryReservation, policy: WorkloadResourceClassPolicy) -> Self {
        let additionalCPU = policy.cpuMicroUnits(cpus: cpus > grantedCPUs ? cpus - grantedCPUs : 0)
        let additionalMemory = policy.memoryReservation(
            WorkloadMemoryReservation(
                guestBytes: max(0, memory.guestBytes - guestCommitmentBytes), backendOverheadBytes: 0)
        ).guestBytes
        let (cpu, cpuOverflow) = cpuMicroUnits.addingReportingOverflow(additionalCPU)
        let (guest, guestOverflow) = discountedGuestBytes.addingReportingOverflow(additionalMemory)
        return Self(
            cpus: max(cpus, grantedCPUs), guest: max(memory.guestBytes, guestCommitmentBytes),
            cpuMicroUnits: cpuOverflow ? .max : cpu, discountedGuest: guestOverflow ? .max : guest,
            overhead: max(backendOverheadBytes, memory.backendOverheadBytes))
    }

    private enum CodingKeys: String, CodingKey {
        case grantedCPUs, guestCommitmentBytes, cpuMicroUnits, discountedGuestBytes, backendOverheadBytes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cpus = try c.decode(Int.self, forKey: .grantedCPUs)
        let guest = try c.decode(Int64.self, forKey: .guestCommitmentBytes)
        let cpu = try c.decode(Int64.self, forKey: .cpuMicroUnits)
        let discounted = try c.decode(Int64.self, forKey: .discountedGuestBytes)
        let overhead = try c.decode(Int64.self, forKey: .backendOverheadBytes)
        guard cpus >= 0, guest >= 0, cpu >= 0, discounted >= 0, discounted <= guest, overhead >= 0 else {
            throw WorkloadResourceClassError.invalidPolicy
        }
        self.init(cpus: cpus, guest: guest, cpuMicroUnits: cpu, discountedGuest: discounted, overhead: overhead)
    }
}

/// Each backend must prove the whole contract before it can be used for burstable work.
/// Ordinary unjailed Firecracker VMs have no corresponding eligible backend case.
public enum WorkloadResourceClassBackend: String, Codable, Sendable {
    case qemuVM
    case jailedFirecrackerSandbox
}

public struct WorkloadResourceClassEnforcement: Codable, Sendable, Equatable {
    public let backend: WorkloadResourceClassBackend
    public let controllersDelegated: Bool
    public let stableOwnership: Bool
    public let preExecutionEnforcement: Bool
    public let effectiveReadback: Bool
    public var supportsBurstable: Bool {
        controllersDelegated && stableOwnership && preExecutionEnforcement && effectiveReadback
    }

    public init(
        backend: WorkloadResourceClassBackend, controllersDelegated: Bool,
        stableOwnership: Bool, preExecutionEnforcement: Bool, effectiveReadback: Bool
    ) {
        self.backend = backend
        self.controllersDelegated = controllersDelegated
        self.stableOwnership = stableOwnership
        self.preExecutionEnforcement = preExecutionEnforcement
        self.effectiveReadback = effectiveReadback
    }
}
