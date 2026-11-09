import Foundation
import SwiftProtobuf

public typealias WorkloadResourceClassKind = Strato_Agent_V1_WorkloadResourceClassKind
extension Strato_Agent_V1_WorkloadResourceClassKind: Codable {

    public var protocolValue: String {
        switch self {
        case .guaranteed: return "guaranteed"
        case .burstable: return "burstable"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "guaranteed": self = .guaranteed
        case "burstable": self = .burstable
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.guaranteed, .burstable] }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

public typealias WorkloadHardLimitPolicy = Strato_Agent_V1_WorkloadHardLimitPolicy
extension Strato_Agent_V1_WorkloadHardLimitPolicy: Codable {

    public var protocolValue: String {
        switch self {
        case .guestAndBackend: return "guestAndBackend"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "guestAndBackend": self = .guestAndBackend
        default: return nil
        }
    }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

public enum WorkloadResourceClassError: String, Error, Sendable {
    case invalidPolicy
    case invalidIdentity
    case invalidRuntimeLimit
    case enforcementUnavailable
}

/// Bounds are configuration limits, not recommendations for safe overcommit.
public typealias WorkloadResourceClassPolicy = Strato_Agent_V1_WorkloadResourceClassPolicy
extension Strato_Agent_V1_WorkloadResourceClassPolicy: Codable {

    public init(
        kind: WorkloadResourceClassKind, cpuAllocationRatio: Double = 1,
        memoryAllocationRatio: Double = 1, cpuWeight: Int = 100,
        memoryHighPercent: Int = 100, hardLimitPolicy: WorkloadHardLimitPolicy = .guestAndBackend,
        maxCPUPressure10: Double = 10, maxMemoryPressure10: Double = 5,
        maxTelemetryAgeSeconds: Int = 60
    ) throws {
        self.init()
        guard hardLimitPolicy == .guestAndBackend,
            cpuAllocationRatio.isFinite, (1...64).contains(cpuAllocationRatio),
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
        case .unspecified, .UNRECOGNIZED:
            throw WorkloadResourceClassError.invalidPolicy
        }
        self._jsonKind = kind
        self._jsonCpuAllocationRatio = cpuAllocationRatio
        self._jsonMemoryAllocationRatio = memoryAllocationRatio
        self._jsonCpuWeight = cpuWeight
        self._jsonMemoryHighPercent = memoryHighPercent
        self._jsonHardLimitPolicy = hardLimitPolicy
        self._jsonMaxCPUPressure10 = maxCPUPressure10
        self._jsonMaxMemoryPressure10 = maxMemoryPressure10
        self._jsonMaxTelemetryAgeSeconds = maxTelemetryAgeSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case kind, cpuAllocationRatio, memoryAllocationRatio, cpuWeight, memoryHighPercent, hardLimitPolicy
        case maxCPUPressure10, maxMemoryPressure10, maxTelemetryAgeSeconds
    }

    public init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        do {
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
        } catch is WorkloadResourceClassError {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Resource class policy is outside validated bounds"))
        }
    }

    public static let guaranteed = try! Self(kind: .guaranteed)
    public static let burstable = try! Self(kind: .burstable, cpuAllocationRatio: 4, memoryHighPercent: 80)

    /// CPU micro-units retain fractional commitment across workloads.
    public func cpuMicroUnits(cpus: Int) -> Int64 {
        Self.ceilingSaturating(Double(max(0, cpus)) * 1_000_000 / _jsonCpuAllocationRatio)
    }

    public func memoryReservation(_ raw: WorkloadMemoryReservation) -> WorkloadMemoryReservation {
        // Preserve guaranteed Int64 operands without a lossy floating-point round trip.
        guard _jsonKind == .burstable, _jsonMemoryAllocationRatio != 1 else { return raw }
        return WorkloadMemoryReservation(
            guestBytes: min(
                raw.guestBytes,
                Self.ceilingSaturating(
                    (raw.guestBytes > 9_007_199_254_740_992 ? Double(raw.guestBytes).nextUp : Double(raw.guestBytes))
                        / _jsonMemoryAllocationRatio)),
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
        let percent = Int64(_jsonMemoryHighPercent)
        let guestHigh = (guestBytes / 100) * percent + ((guestBytes % 100) * percent) / 100
        let high = guestHigh + backendOverheadBytes
        guard _jsonKind == .guaranteed || (high > 0 && high < maximum) else {
            throw WorkloadResourceClassError.invalidRuntimeLimit
        }
        return WorkloadRuntimeLimits(memoryHighBytes: high, memoryMaxBytes: maximum, cpuWeight: _jsonCpuWeight)
    }

    /// An unavailable or stale required signal cannot be treated as healthy zero pressure.
    public func admissionRefusal(telemetry: HostResourceTelemetry?, now: Date, receivedAt: Date? = nil) -> String? {
        guard _jsonKind == .burstable else { return nil }
        guard let telemetry else { return "burstable admission requires fresh host pressure telemetry" }
        let observationTime = receivedAt ?? telemetry._jsonSampledAt
        guard observationTime <= now,
            now.timeIntervalSince(observationTime) <= Double(_jsonMaxTelemetryAgeSeconds)
        else { return "burstable admission requires fresh host pressure telemetry" }
        guard telemetry._jsonCpuPressure._jsonAvailability == .available,
            telemetry._jsonMemoryPressure._jsonAvailability == .available,
            let cpu = telemetry._jsonCpuPressure._jsonSome?.average10,
            let memory = telemetry._jsonMemoryPressure._jsonSome?.average10,
            cpu.isFinite, memory.isFinite, cpu >= 0, memory >= 0
        else { return "burstable admission requires available CPU and memory PSI" }
        guard cpu <= _jsonMaxCPUPressure10 else { return "CPU PSI exceeds the resource class admission gate" }
        guard memory <= _jsonMaxMemoryPressure10 else { return "memory PSI exceeds the resource class admission gate" }
        return nil
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonKind, forKey: .kind)
        try container.encode(_jsonCpuAllocationRatio, forKey: .cpuAllocationRatio)
        try container.encode(_jsonMemoryAllocationRatio, forKey: .memoryAllocationRatio)
        try container.encode(_jsonCpuWeight, forKey: .cpuWeight)
        try container.encode(_jsonMemoryHighPercent, forKey: .memoryHighPercent)
        try container.encode(_jsonHardLimitPolicy, forKey: .hardLimitPolicy)
        try container.encode(_jsonMaxCPUPressure10, forKey: .maxCPUPressure10)
        try container.encode(_jsonMaxMemoryPressure10, forKey: .maxMemoryPressure10)
        try container.encode(_jsonMaxTelemetryAgeSeconds, forKey: .maxTelemetryAgeSeconds)
    }

    var _jsonKind: WorkloadResourceClassKind {
        get { kind }
        set { let value = newValue; kind = value }
    }
    var _jsonCpuAllocationRatio: Double {
        get { cpuAllocationRatio }
        set { let value = newValue; cpuAllocationRatio = value }
    }
    var _jsonMemoryAllocationRatio: Double {
        get { memoryAllocationRatio }
        set { let value = newValue; memoryAllocationRatio = value }
    }
    var _jsonCpuWeight: Int {
        get { Int(cpuWeight) }
        set { let value = newValue; cpuWeight = Int64(value) }
    }
    var _jsonMemoryHighPercent: Int {
        get { Int(memoryHighPercent) }
        set { let value = newValue; memoryHighPercent = Int64(value) }
    }
    var _jsonHardLimitPolicy: WorkloadHardLimitPolicy {
        get { hardLimitPolicy }
        set { let value = newValue; hardLimitPolicy = value }
    }
    var _jsonMaxCPUPressure10: Double {
        get { maxCpuPressure10 }
        set { let value = newValue; maxCpuPressure10 = value }
    }
    var _jsonMaxMemoryPressure10: Double {
        get { maxMemoryPressure10 }
        set { let value = newValue; maxMemoryPressure10 = value }
    }
    var _jsonMaxTelemetryAgeSeconds: Int {
        get { Int(maxTelemetryAgeSeconds) }
        set { let value = newValue; maxTelemetryAgeSeconds = Int64(value) }
    }
}

public typealias WorkloadRuntimeLimits = Strato_Agent_V1_WorkloadRuntimeLimits
extension Strato_Agent_V1_WorkloadRuntimeLimits: Codable {
    /// Kernel memory counters use base pages. Both drivers must normalize before
    /// applying or comparing readback; libvirt then expresses these exact pages in KiB.
    public func aligned(pageSizeBytes: Int64) throws -> Self {
        guard pageSizeBytes >= 1024, pageSizeBytes & (pageSizeBytes - 1) == 0,
            _jsonMemoryHighBytes > 0, _jsonMemoryHighBytes < _jsonMemoryMaxBytes
        else {
            throw WorkloadResourceClassError.invalidRuntimeLimit
        }
        let high = (_jsonMemoryHighBytes / pageSizeBytes) * pageSizeBytes
        let remainder = _jsonMemoryMaxBytes % pageSizeBytes
        let (maximum, overflow) = _jsonMemoryMaxBytes.addingReportingOverflow(
            remainder == 0 ? 0 : pageSizeBytes - remainder)
        guard !overflow, high > 0, high < maximum else {
            throw WorkloadResourceClassError.invalidRuntimeLimit
        }
        return Self(memoryHighBytes: high, memoryMaxBytes: maximum, cpuWeight: _jsonCpuWeight)
    }

    public init(memoryHighBytes: Int64, memoryMaxBytes: Int64, cpuWeight: Int) {
        self.init()
        self._jsonMemoryHighBytes = memoryHighBytes
        self._jsonMemoryMaxBytes = memoryMaxBytes
        self._jsonCpuWeight = cpuWeight
    }

    private enum CodingKeys: String, CodingKey { case memoryHighBytes; case memoryMaxBytes; case cpuWeight }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonMemoryHighBytes = try container.decode(Int64.self, forKey: .memoryHighBytes)
        self._jsonMemoryMaxBytes = try container.decode(Int64.self, forKey: .memoryMaxBytes)
        self._jsonCpuWeight = try container.decode(Int.self, forKey: .cpuWeight)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonMemoryHighBytes, forKey: .memoryHighBytes)
        try container.encode(_jsonMemoryMaxBytes, forKey: .memoryMaxBytes)
        try container.encode(_jsonCpuWeight, forKey: .cpuWeight)
    }

    var _jsonMemoryHighBytes: Int64 {
        get { memoryHighBytes }
        set { let value = newValue; memoryHighBytes = value }
    }
    var _jsonMemoryMaxBytes: Int64 {
        get { memoryMaxBytes }
        set { let value = newValue; memoryMaxBytes = value }
    }
    var _jsonCpuWeight: Int {
        get { Int(cpuWeight) }
        set { let value = newValue; cpuWeight = Int64(value) }
    }
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
public typealias WorkloadResourceClassSnapshot = Strato_Agent_V1_WorkloadResourceClassSnapshot
extension Strato_Agent_V1_WorkloadResourceClassSnapshot: Codable {
    public static let guaranteedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let burstableID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    public init(classID: UUID, siteID: UUID, revision: Int64, policy: WorkloadResourceClassPolicy) throws {
        self.init()
        guard revision > 0,
            (policy._jsonKind == .guaranteed && classID == Self.guaranteedID && revision == 1)
                || (policy._jsonKind == .burstable && classID == Self.burstableID)
        else { throw WorkloadResourceClassError.invalidIdentity }
        self._jsonClassID = classID
        self._jsonSiteID = siteID
        self._jsonRevision = revision
        self._jsonPolicy = policy
    }

    private enum CodingKeys: String, CodingKey { case classID, siteID, revision }

    public init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            classID: c.decode(UUID.self, forKey: .classID), siteID: c.decode(UUID.self, forKey: .siteID),
            revision: c.decode(Int64.self, forKey: .revision), policy: WorkloadResourceClassPolicy(from: decoder))
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        try _jsonPolicy.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(_jsonClassID, forKey: .classID)
        try c.encode(_jsonSiteID, forKey: .siteID)
        try c.encode(_jsonRevision, forKey: .revision)
    }

    var _jsonClassID: UUID {
        get { UUID(uuidString: classID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; classID = value.uuidString }
    }
    var _jsonSiteID: UUID {
        get { UUID(uuidString: siteID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; siteID = value.uuidString }
    }
    var _jsonRevision: Int64 {
        get { revision }
        set { let value = newValue; revision = value }
    }
    var _jsonPolicy: WorkloadResourceClassPolicy {
        get { policy }
        set { let value = newValue; policy = value }
    }
}

/// A durable physical commitment. Growth prices only newly admitted guest/CPU
/// units; catalog edits cannot reprice the previous grant.
public typealias WorkloadAdmittedReservation = Strato_Agent_V1_WorkloadAdmittedReservation
extension Strato_Agent_V1_WorkloadAdmittedReservation: Codable {
    public var effectiveMemoryBytes: Int64 {
        WorkloadMemoryReservation(
            guestBytes: _jsonDiscountedGuestBytes, backendOverheadBytes: _jsonBackendOverheadBytes
        )
        .effectiveBytes
    }

    public init(cpus: Int, memory: WorkloadMemoryReservation, policy: WorkloadResourceClassPolicy) {
        self.init()
        self._jsonGrantedCPUs = max(0, cpus)
        self._jsonGuestCommitmentBytes = memory.guestBytes
        self._jsonCpuMicroUnits = policy.cpuMicroUnits(cpus: cpus)
        self._jsonDiscountedGuestBytes = policy.memoryReservation(memory).guestBytes
        self._jsonBackendOverheadBytes = memory.backendOverheadBytes
    }

    private init(cpus: Int, guest: Int64, cpuMicroUnits: Int64, discountedGuest: Int64, overhead: Int64) {
        self.init()
        _jsonGrantedCPUs = cpus
        _jsonGuestCommitmentBytes = guest
        self._jsonCpuMicroUnits = cpuMicroUnits
        _jsonDiscountedGuestBytes = discountedGuest
        _jsonBackendOverheadBytes = overhead
    }

    public func growing(cpus: Int, memory: WorkloadMemoryReservation, policy: WorkloadResourceClassPolicy) -> Self {
        let additionalCPU = policy.cpuMicroUnits(cpus: cpus > _jsonGrantedCPUs ? cpus - _jsonGrantedCPUs : 0)
        let additionalMemory = policy.memoryReservation(
            WorkloadMemoryReservation(
                guestBytes: max(0, memory.guestBytes - _jsonGuestCommitmentBytes), backendOverheadBytes: 0)
        ).guestBytes
        let (cpu, cpuOverflow) = _jsonCpuMicroUnits.addingReportingOverflow(additionalCPU)
        let (guest, guestOverflow) = _jsonDiscountedGuestBytes.addingReportingOverflow(additionalMemory)
        return Self(
            cpus: max(cpus, _jsonGrantedCPUs), guest: max(memory.guestBytes, _jsonGuestCommitmentBytes),
            cpuMicroUnits: cpuOverflow ? .max : cpu, discountedGuest: guestOverflow ? .max : guest,
            overhead: max(_jsonBackendOverheadBytes, memory.backendOverheadBytes))
    }

    private enum CodingKeys: String, CodingKey {
        case grantedCPUs, guestCommitmentBytes, cpuMicroUnits, discountedGuestBytes, backendOverheadBytes
    }

    public init(from decoder: any Swift.Decoder) throws {
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

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonGrantedCPUs, forKey: .grantedCPUs)
        try container.encode(_jsonGuestCommitmentBytes, forKey: .guestCommitmentBytes)
        try container.encode(_jsonCpuMicroUnits, forKey: .cpuMicroUnits)
        try container.encode(_jsonDiscountedGuestBytes, forKey: .discountedGuestBytes)
        try container.encode(_jsonBackendOverheadBytes, forKey: .backendOverheadBytes)
    }

    var _jsonGrantedCPUs: Int {
        get { Int(grantedCpUs) }
        set { let value = newValue; grantedCpUs = Int64(value) }
    }
    var _jsonGuestCommitmentBytes: Int64 {
        get { guestCommitmentBytes }
        set { let value = newValue; guestCommitmentBytes = value }
    }
    var _jsonCpuMicroUnits: Int64 {
        get { cpuMicroUnits }
        set { let value = newValue; cpuMicroUnits = value }
    }
    var _jsonDiscountedGuestBytes: Int64 {
        get { discountedGuestBytes }
        set { let value = newValue; discountedGuestBytes = value }
    }
    var _jsonBackendOverheadBytes: Int64 {
        get { backendOverheadBytes }
        set { let value = newValue; backendOverheadBytes = value }
    }
}

/// Each backend must prove the whole contract before it can be used for burstable work.
/// Ordinary unjailed Firecracker VMs have no corresponding eligible backend case.
public typealias WorkloadResourceClassBackend = Strato_Agent_V1_WorkloadResourceClassBackend
extension Strato_Agent_V1_WorkloadResourceClassBackend: Codable {

    public var protocolValue: String {
        switch self {
        case .qemuVm: return "qemuVM"
        case .jailedFirecrackerSandbox: return "jailedFirecrackerSandbox"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "qemuVM": self = .qemuVm
        case "jailedFirecrackerSandbox": self = .jailedFirecrackerSandbox
        default: return nil
        }
    }

    public static var qemuVM: Self { .qemuVm }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

public typealias WorkloadResourceClassEnforcement = Strato_Agent_V1_WorkloadResourceClassEnforcement
extension Strato_Agent_V1_WorkloadResourceClassEnforcement: Codable {
    public var supportsBurstable: Bool {
        _jsonControllersDelegated && _jsonStableOwnership && _jsonPreExecutionEnforcement && _jsonEffectiveReadback
    }

    public init(
        backend: WorkloadResourceClassBackend, controllersDelegated: Bool,
        stableOwnership: Bool, preExecutionEnforcement: Bool, effectiveReadback: Bool
    ) {
        self.init()
        self._jsonBackend = backend
        self._jsonControllersDelegated = controllersDelegated
        self._jsonStableOwnership = stableOwnership
        self._jsonPreExecutionEnforcement = preExecutionEnforcement
        self._jsonEffectiveReadback = effectiveReadback
    }

    private enum CodingKeys: String, CodingKey {
        case backend; case controllersDelegated; case stableOwnership; case preExecutionEnforcement;
        case effectiveReadback
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonBackend = try container.decode(WorkloadResourceClassBackend.self, forKey: .backend)
        self._jsonControllersDelegated = try container.decode(Bool.self, forKey: .controllersDelegated)
        self._jsonStableOwnership = try container.decode(Bool.self, forKey: .stableOwnership)
        self._jsonPreExecutionEnforcement = try container.decode(Bool.self, forKey: .preExecutionEnforcement)
        self._jsonEffectiveReadback = try container.decode(Bool.self, forKey: .effectiveReadback)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonBackend, forKey: .backend)
        try container.encode(_jsonControllersDelegated, forKey: .controllersDelegated)
        try container.encode(_jsonStableOwnership, forKey: .stableOwnership)
        try container.encode(_jsonPreExecutionEnforcement, forKey: .preExecutionEnforcement)
        try container.encode(_jsonEffectiveReadback, forKey: .effectiveReadback)
    }

    var _jsonBackend: WorkloadResourceClassBackend {
        get { backend }
        set { let value = newValue; backend = value }
    }
    var _jsonControllersDelegated: Bool {
        get { controllersDelegated }
        set { let value = newValue; controllersDelegated = value }
    }
    var _jsonStableOwnership: Bool {
        get { stableOwnership }
        set { let value = newValue; stableOwnership = value }
    }
    var _jsonPreExecutionEnforcement: Bool {
        get { preExecutionEnforcement }
        set { let value = newValue; preExecutionEnforcement = value }
    }
    var _jsonEffectiveReadback: Bool {
        get { effectiveReadback }
        set { let value = newValue; effectiveReadback = value }
    }
}
