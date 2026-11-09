import Foundation
import SwiftProtobuf

/// Whether a resource signal was measured in the latest sampling pass.
///
/// Availability is part of every scalar signal so an unsupported kernel,
/// backend, or guest source cannot be mistaken for a measured zero. A failed
/// read is also unavailable: the next independent sampling pass retries it.
public typealias ResourceTelemetryAvailability = Strato_Agent_V1_ResourceTelemetryAvailability
extension Strato_Agent_V1_ResourceTelemetryAvailability: Codable {

    public var protocolValue: String {
        switch self {
        case .available: return "available"
        case .unavailable: return "unavailable"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "available": self = .available
        case "unavailable": self = .unavailable
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

/// An integer resource signal together with explicit availability.
///
/// Counters (faults, reclaim, CPU time) and gauges (bytes) share this wire
/// shape. Their names document their temporality; keeping one representation
/// makes absence handling identical everywhere.
public typealias ResourceTelemetryValue = Strato_Agent_V1_ResourceTelemetryValue
extension Strato_Agent_V1_ResourceTelemetryValue: Codable {

    public init(availability: ResourceTelemetryAvailability, value: Int64? = nil) {
        self.init()
        self._jsonAvailability = availability
        self._jsonValue = availability == .available ? value : nil
    }

    public static func available(_ value: Int64) -> Self {
        Self(availability: .available, value: value)
    }

    public static let unavailable = Self(availability: .unavailable)

    private enum CodingKeys: String, CodingKey { case availability; case value }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonAvailability = try container.decode(ResourceTelemetryAvailability.self, forKey: .availability)
        self._jsonValue = try container.decodeIfPresent(Int64.self, forKey: .value)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonAvailability, forKey: .availability)
        try container.encodeIfPresent(_jsonValue, forKey: .value)
    }

    var _jsonAvailability: ResourceTelemetryAvailability {
        get { availability }
        set { let value = newValue; availability = value }
    }
    var _jsonValue: Int64? {
        get { hasValue ? (value) : nil }
        set { if let value = newValue { self.value = value } else { clearValue() } }
    }
}

/// A boolean capability or state with explicit availability.
public typealias ResourceTelemetryFlag = Strato_Agent_V1_ResourceTelemetryFlag
extension Strato_Agent_V1_ResourceTelemetryFlag: Codable {

    public init(availability: ResourceTelemetryAvailability, value: Bool? = nil) {
        self.init()
        self._jsonAvailability = availability
        self._jsonValue = availability == .available ? value : nil
    }

    public static func available(_ value: Bool) -> Self {
        Self(availability: .available, value: value)
    }

    public static let unavailable = Self(availability: .unavailable)

    private enum CodingKeys: String, CodingKey { case availability; case value }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonAvailability = try container.decode(ResourceTelemetryAvailability.self, forKey: .availability)
        self._jsonValue = try container.decodeIfPresent(Bool.self, forKey: .value)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonAvailability, forKey: .availability)
        try container.encodeIfPresent(_jsonValue, forKey: .value)
    }

    var _jsonAvailability: ResourceTelemetryAvailability {
        get { availability }
        set { let value = newValue; availability = value }
    }
    var _jsonValue: Bool? {
        get { hasValue ? (value) : nil }
        set { if let value = newValue { self.value = value } else { clearValue() } }
    }
}

/// One Linux PSI `some` or `full` line.
public typealias PressureStallSample = Strato_Agent_V1_PressureStallSample
extension Strato_Agent_V1_PressureStallSample: Codable {
    /// Percentage of wall time stalled over the last 10, 60, and 300 seconds.
    /// Cumulative stalled time since boot/cgroup creation, in microseconds.

    public init(
        average10: Double,
        average60: Double,
        average300: Double,
        totalMicroseconds: Int64
    ) {
        self.init()
        self._jsonAverage10 = average10
        self._jsonAverage60 = average60
        self._jsonAverage300 = average300
        self._jsonTotalMicroseconds = totalMicroseconds
    }

    private enum CodingKeys: String, CodingKey {
        case average10; case average60; case average300; case totalMicroseconds
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonAverage10 = try container.decode(Double.self, forKey: .average10)
        self._jsonAverage60 = try container.decode(Double.self, forKey: .average60)
        self._jsonAverage300 = try container.decode(Double.self, forKey: .average300)
        self._jsonTotalMicroseconds = try container.decode(Int64.self, forKey: .totalMicroseconds)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonAverage10, forKey: .average10)
        try container.encode(_jsonAverage60, forKey: .average60)
        try container.encode(_jsonAverage300, forKey: .average300)
        try container.encode(_jsonTotalMicroseconds, forKey: .totalMicroseconds)
    }

    var _jsonAverage10: Double {
        get { average10 }
        set { let value = newValue; average10 = value }
    }
    var _jsonAverage60: Double {
        get { average60 }
        set { let value = newValue; average60 = value }
    }
    var _jsonAverage300: Double {
        get { average300 }
        set { let value = newValue; average300 = value }
    }
    var _jsonTotalMicroseconds: Int64 {
        get { totalMicroseconds }
        set { let value = newValue; totalMicroseconds = value }
    }
}

/// One PSI resource file. `full` is independently optional because CPU PSI
/// and older kernels may expose only `some` while still providing a valid
/// signal. A measured all-zero line remains present and distinct from absence.
public typealias PressureStallTelemetry = Strato_Agent_V1_PressureStallTelemetry
extension Strato_Agent_V1_PressureStallTelemetry: Codable {

    public init(
        availability: ResourceTelemetryAvailability,
        some: PressureStallSample? = nil,
        full: PressureStallSample? = nil
    ) {
        self.init()
        self._jsonAvailability = availability
        self._jsonSome = availability == .available ? some : nil
        self._jsonFull = availability == .available ? full : nil
    }

    public static func available(
        some: PressureStallSample?, full: PressureStallSample?
    ) -> Self {
        Self(availability: .available, some: some, full: full)
    }

    public static let unavailable = Self(availability: .unavailable)

    private enum CodingKeys: String, CodingKey { case availability; case some; case full }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonAvailability = try container.decode(ResourceTelemetryAvailability.self, forKey: .availability)
        self._jsonSome = try container.decodeIfPresent(PressureStallSample.self, forKey: .some)
        self._jsonFull = try container.decodeIfPresent(PressureStallSample.self, forKey: .full)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonAvailability, forKey: .availability)
        try container.encodeIfPresent(_jsonSome, forKey: .some)
        try container.encodeIfPresent(_jsonFull, forKey: .full)
    }

    var _jsonAvailability: ResourceTelemetryAvailability {
        get { availability }
        set { let value = newValue; availability = value }
    }
    var _jsonSome: PressureStallSample? {
        get { hasSome ? (some) : nil }
        set { if let value = newValue { some = value } else { clearSome() } }
    }
    var _jsonFull: PressureStallSample? {
        get { hasFull ? (full) : nil }
        set { if let value = newValue { full = value } else { clearFull() } }
    }
}

/// Operator-facing pressure summary. Raw signals remain the alert authority;
/// this bounded state is the compact field later placement policy can consume.
public typealias ResourcePressureHealth = Strato_Agent_V1_ResourcePressureHealth
extension Strato_Agent_V1_ResourcePressureHealth: Codable {

    public var protocolValue: String {
        switch self {
        case .unknown: return "unknown"
        case .healthy: return "healthy"
        case .pressured: return "pressured"
        case .critical: return "critical"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "unknown": self = .unknown
        case "healthy": self = .healthy
        case "pressured": self = .pressured
        case "critical": self = .critical
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

/// Host-wide pressure, reclaim, swap, and OOM observations.
public typealias HostResourceTelemetry = Strato_Agent_V1_HostResourceTelemetry
extension Strato_Agent_V1_HostResourceTelemetry: Codable {
    /// Bytes of original pages currently represented in zswap.
    /// Bytes currently consumed by zswap's compressed pool.
    /// Sum of `mem_used_total` across the host's zram block devices.
    /// Available false means the kernel exposes MGLRU but it is disabled;
    /// unavailable means this kernel exposes no MGLRU control at all.

    public init(
        sampledAt: Date,
        health: ResourcePressureHealth,
        cpuPressure: PressureStallTelemetry,
        memoryPressure: PressureStallTelemetry,
        ioPressure: PressureStallTelemetry,
        swapTotalBytes: ResourceTelemetryValue,
        swapUsedBytes: ResourceTelemetryValue,
        zswapStoredBytes: ResourceTelemetryValue,
        zswapPoolBytes: ResourceTelemetryValue,
        zramUsedBytes: ResourceTelemetryValue,
        majorFaultsTotal: ResourceTelemetryValue,
        reclaimScannedPagesTotal: ResourceTelemetryValue,
        reclaimReclaimedPagesTotal: ResourceTelemetryValue,
        oomKillsTotal: ResourceTelemetryValue,
        mglruEnabled: ResourceTelemetryFlag,
        memoryProfile: HostMemoryProfileObservation? = nil,
        swapInPagesTotal: ResourceTelemetryValue? = nil,
        swapOutPagesTotal: ResourceTelemetryValue? = nil,
        zramOriginalBytes: ResourceTelemetryValue? = nil,
        swapInPagesPerSecond: Double? = nil,
        swapOutPagesPerSecond: Double? = nil,
        memoryWarnings: [String]? = nil
    ) {
        self.init()
        self._jsonSampledAt = sampledAt
        self._jsonHealth = health
        self._jsonCpuPressure = cpuPressure
        self._jsonMemoryPressure = memoryPressure
        self._jsonIoPressure = ioPressure
        self._jsonSwapTotalBytes = swapTotalBytes
        self._jsonSwapUsedBytes = swapUsedBytes
        self._jsonZswapStoredBytes = zswapStoredBytes
        self._jsonZswapPoolBytes = zswapPoolBytes
        self._jsonZramUsedBytes = zramUsedBytes
        self._jsonMajorFaultsTotal = majorFaultsTotal
        self._jsonReclaimScannedPagesTotal = reclaimScannedPagesTotal
        self._jsonReclaimReclaimedPagesTotal = reclaimReclaimedPagesTotal
        self._jsonOomKillsTotal = oomKillsTotal
        self._jsonMglruEnabled = mglruEnabled
        self._jsonMemoryProfile = memoryProfile
        self._jsonSwapInPagesTotal = swapInPagesTotal
        self._jsonSwapOutPagesTotal = swapOutPagesTotal
        self._jsonZramOriginalBytes = zramOriginalBytes
        self._jsonSwapInPagesPerSecond = swapInPagesPerSecond
        self._jsonSwapOutPagesPerSecond = swapOutPagesPerSecond
        self._jsonMemoryWarnings = memoryWarnings
    }

    private enum CodingKeys: String, CodingKey {
        case sampledAt; case health; case cpuPressure; case memoryPressure; case ioPressure; case swapTotalBytes;
        case swapUsedBytes; case zswapStoredBytes; case zswapPoolBytes; case zramUsedBytes; case majorFaultsTotal;
        case reclaimScannedPagesTotal; case reclaimReclaimedPagesTotal; case oomKillsTotal; case mglruEnabled;
        case memoryProfile; case swapInPagesTotal; case swapOutPagesTotal; case zramOriginalBytes;
        case swapInPagesPerSecond; case swapOutPagesPerSecond; case memoryWarnings
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonSampledAt = try container.decode(Date.self, forKey: .sampledAt)
        self._jsonHealth = try container.decode(ResourcePressureHealth.self, forKey: .health)
        self._jsonCpuPressure = try container.decode(PressureStallTelemetry.self, forKey: .cpuPressure)
        self._jsonMemoryPressure = try container.decode(PressureStallTelemetry.self, forKey: .memoryPressure)
        self._jsonIoPressure = try container.decode(PressureStallTelemetry.self, forKey: .ioPressure)
        self._jsonSwapTotalBytes = try container.decode(ResourceTelemetryValue.self, forKey: .swapTotalBytes)
        self._jsonSwapUsedBytes = try container.decode(ResourceTelemetryValue.self, forKey: .swapUsedBytes)
        self._jsonZswapStoredBytes = try container.decode(ResourceTelemetryValue.self, forKey: .zswapStoredBytes)
        self._jsonZswapPoolBytes = try container.decode(ResourceTelemetryValue.self, forKey: .zswapPoolBytes)
        self._jsonZramUsedBytes = try container.decode(ResourceTelemetryValue.self, forKey: .zramUsedBytes)
        self._jsonMajorFaultsTotal = try container.decode(ResourceTelemetryValue.self, forKey: .majorFaultsTotal)
        self._jsonReclaimScannedPagesTotal = try container.decode(
            ResourceTelemetryValue.self, forKey: .reclaimScannedPagesTotal)
        self._jsonReclaimReclaimedPagesTotal = try container.decode(
            ResourceTelemetryValue.self, forKey: .reclaimReclaimedPagesTotal)
        self._jsonOomKillsTotal = try container.decode(ResourceTelemetryValue.self, forKey: .oomKillsTotal)
        self._jsonMglruEnabled = try container.decode(ResourceTelemetryFlag.self, forKey: .mglruEnabled)
        self._jsonMemoryProfile = try container.decodeIfPresent(
            HostMemoryProfileObservation.self, forKey: .memoryProfile)
        self._jsonSwapInPagesTotal = try container.decodeIfPresent(
            ResourceTelemetryValue.self, forKey: .swapInPagesTotal)
        self._jsonSwapOutPagesTotal = try container.decodeIfPresent(
            ResourceTelemetryValue.self, forKey: .swapOutPagesTotal)
        self._jsonZramOriginalBytes = try container.decodeIfPresent(
            ResourceTelemetryValue.self, forKey: .zramOriginalBytes)
        self._jsonSwapInPagesPerSecond = try container.decodeIfPresent(Double.self, forKey: .swapInPagesPerSecond)
        self._jsonSwapOutPagesPerSecond = try container.decodeIfPresent(Double.self, forKey: .swapOutPagesPerSecond)
        self._jsonMemoryWarnings = try container.decodeIfPresent([String].self, forKey: .memoryWarnings)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonSampledAt, forKey: .sampledAt)
        try container.encode(_jsonHealth, forKey: .health)
        try container.encode(_jsonCpuPressure, forKey: .cpuPressure)
        try container.encode(_jsonMemoryPressure, forKey: .memoryPressure)
        try container.encode(_jsonIoPressure, forKey: .ioPressure)
        try container.encode(_jsonSwapTotalBytes, forKey: .swapTotalBytes)
        try container.encode(_jsonSwapUsedBytes, forKey: .swapUsedBytes)
        try container.encode(_jsonZswapStoredBytes, forKey: .zswapStoredBytes)
        try container.encode(_jsonZswapPoolBytes, forKey: .zswapPoolBytes)
        try container.encode(_jsonZramUsedBytes, forKey: .zramUsedBytes)
        try container.encode(_jsonMajorFaultsTotal, forKey: .majorFaultsTotal)
        try container.encode(_jsonReclaimScannedPagesTotal, forKey: .reclaimScannedPagesTotal)
        try container.encode(_jsonReclaimReclaimedPagesTotal, forKey: .reclaimReclaimedPagesTotal)
        try container.encode(_jsonOomKillsTotal, forKey: .oomKillsTotal)
        try container.encode(_jsonMglruEnabled, forKey: .mglruEnabled)
        try container.encodeIfPresent(_jsonMemoryProfile, forKey: .memoryProfile)
        try container.encodeIfPresent(_jsonSwapInPagesTotal, forKey: .swapInPagesTotal)
        try container.encodeIfPresent(_jsonSwapOutPagesTotal, forKey: .swapOutPagesTotal)
        try container.encodeIfPresent(_jsonZramOriginalBytes, forKey: .zramOriginalBytes)
        try container.encodeIfPresent(_jsonSwapInPagesPerSecond, forKey: .swapInPagesPerSecond)
        try container.encodeIfPresent(_jsonSwapOutPagesPerSecond, forKey: .swapOutPagesPerSecond)
        try container.encodeIfPresent(_jsonMemoryWarnings, forKey: .memoryWarnings)
    }

    var _jsonSampledAt: Date {
        get { sampledAt.date }
        set { let value = newValue; sampledAt = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonHealth: ResourcePressureHealth {
        get { health }
        set { let value = newValue; health = value }
    }
    var _jsonCpuPressure: PressureStallTelemetry {
        get { cpuPressure }
        set { let value = newValue; cpuPressure = value }
    }
    var _jsonMemoryPressure: PressureStallTelemetry {
        get { memoryPressure }
        set { let value = newValue; memoryPressure = value }
    }
    var _jsonIoPressure: PressureStallTelemetry {
        get { ioPressure }
        set { let value = newValue; ioPressure = value }
    }
    var _jsonSwapTotalBytes: ResourceTelemetryValue {
        get { swapTotalBytes }
        set { let value = newValue; swapTotalBytes = value }
    }
    var _jsonSwapUsedBytes: ResourceTelemetryValue {
        get { swapUsedBytes }
        set { let value = newValue; swapUsedBytes = value }
    }
    var _jsonZswapStoredBytes: ResourceTelemetryValue {
        get { zswapStoredBytes }
        set { let value = newValue; zswapStoredBytes = value }
    }
    var _jsonZswapPoolBytes: ResourceTelemetryValue {
        get { zswapPoolBytes }
        set { let value = newValue; zswapPoolBytes = value }
    }
    var _jsonZramUsedBytes: ResourceTelemetryValue {
        get { zramUsedBytes }
        set { let value = newValue; zramUsedBytes = value }
    }
    var _jsonMajorFaultsTotal: ResourceTelemetryValue {
        get { majorFaultsTotal }
        set { let value = newValue; majorFaultsTotal = value }
    }
    var _jsonReclaimScannedPagesTotal: ResourceTelemetryValue {
        get { reclaimScannedPagesTotal }
        set { let value = newValue; reclaimScannedPagesTotal = value }
    }
    var _jsonReclaimReclaimedPagesTotal: ResourceTelemetryValue {
        get { reclaimReclaimedPagesTotal }
        set { let value = newValue; reclaimReclaimedPagesTotal = value }
    }
    var _jsonOomKillsTotal: ResourceTelemetryValue {
        get { oomKillsTotal }
        set { let value = newValue; oomKillsTotal = value }
    }
    var _jsonMglruEnabled: ResourceTelemetryFlag {
        get { mglruEnabled }
        set { let value = newValue; mglruEnabled = value }
    }
    var _jsonMemoryProfile: HostMemoryProfileObservation? {
        get { hasMemoryProfile ? (memoryProfile) : nil }
        set { if let value = newValue { memoryProfile = value } else { clearMemoryProfile() } }
    }
    var _jsonSwapInPagesTotal: ResourceTelemetryValue? {
        get { hasSwapInPagesTotal ? (swapInPagesTotal) : nil }
        set { if let value = newValue { swapInPagesTotal = value } else { clearSwapInPagesTotal() } }
    }
    var _jsonSwapOutPagesTotal: ResourceTelemetryValue? {
        get { hasSwapOutPagesTotal ? (swapOutPagesTotal) : nil }
        set { if let value = newValue { swapOutPagesTotal = value } else { clearSwapOutPagesTotal() } }
    }
    var _jsonZramOriginalBytes: ResourceTelemetryValue? {
        get { hasZramOriginalBytes ? (zramOriginalBytes) : nil }
        set { if let value = newValue { zramOriginalBytes = value } else { clearZramOriginalBytes() } }
    }
    var _jsonSwapInPagesPerSecond: Double? {
        get { hasSwapInPagesPerSecond ? (swapInPagesPerSecond) : nil }
        set { if let value = newValue { swapInPagesPerSecond = value } else { clearSwapInPagesPerSecond() } }
    }
    var _jsonSwapOutPagesPerSecond: Double? {
        get { hasSwapOutPagesPerSecond ? (swapOutPagesPerSecond) : nil }
        set { if let value = newValue { swapOutPagesPerSecond = value } else { clearSwapOutPagesPerSecond() } }
    }
    var _jsonMemoryWarnings: [String]? {
        get { hasMemoryWarnings ? (memoryWarnings.values) : nil }
        set {
            if let value = newValue {
                memoryWarnings = Strato_Agent_V1_HostResourceTelemetryMemoryWarningsSection.with { $0.values = value }
            } else {
                clearMemoryWarnings()
            }
        }
    }
}

/// Monotonic counters from cgroup v2 `memory.events`.
public typealias WorkloadMemoryEventsTelemetry = Strato_Agent_V1_WorkloadMemoryEventsTelemetry
extension Strato_Agent_V1_WorkloadMemoryEventsTelemetry: Codable {

    public init(
        availability: ResourceTelemetryAvailability,
        low: Int64? = nil,
        high: Int64? = nil,
        max: Int64? = nil,
        oom: Int64? = nil,
        oomKill: Int64? = nil,
        oomGroupKill: Int64? = nil
    ) {
        self.init()
        self._jsonAvailability = availability
        self._jsonLow = availability == .available ? low : nil
        self._jsonHigh = availability == .available ? high : nil
        self._jsonMax = availability == .available ? max : nil
        self._jsonOom = availability == .available ? oom : nil
        self._jsonOomKill = availability == .available ? oomKill : nil
        self._jsonOomGroupKill = availability == .available ? oomGroupKill : nil
    }

    public static let unavailable = Self(availability: .unavailable)

    private enum CodingKeys: String, CodingKey {
        case availability; case low; case high; case max; case oom; case oomKill; case oomGroupKill
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonAvailability = try container.decode(ResourceTelemetryAvailability.self, forKey: .availability)
        self._jsonLow = try container.decodeIfPresent(Int64.self, forKey: .low)
        self._jsonHigh = try container.decodeIfPresent(Int64.self, forKey: .high)
        self._jsonMax = try container.decodeIfPresent(Int64.self, forKey: .max)
        self._jsonOom = try container.decodeIfPresent(Int64.self, forKey: .oom)
        self._jsonOomKill = try container.decodeIfPresent(Int64.self, forKey: .oomKill)
        self._jsonOomGroupKill = try container.decodeIfPresent(Int64.self, forKey: .oomGroupKill)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonAvailability, forKey: .availability)
        try container.encodeIfPresent(_jsonLow, forKey: .low)
        try container.encodeIfPresent(_jsonHigh, forKey: .high)
        try container.encodeIfPresent(_jsonMax, forKey: .max)
        try container.encodeIfPresent(_jsonOom, forKey: .oom)
        try container.encodeIfPresent(_jsonOomKill, forKey: .oomKill)
        try container.encodeIfPresent(_jsonOomGroupKill, forKey: .oomGroupKill)
    }

    var _jsonAvailability: ResourceTelemetryAvailability {
        get { availability }
        set { let value = newValue; availability = value }
    }
    var _jsonLow: Int64? {
        get { hasLow ? (low) : nil }
        set { if let value = newValue { low = value } else { clearLow() } }
    }
    var _jsonHigh: Int64? {
        get { hasHigh ? (high) : nil }
        set { if let value = newValue { high = value } else { clearHigh() } }
    }
    var _jsonMax: Int64? {
        get { hasMax ? (max) : nil }
        set { if let value = newValue { max = value } else { clearMax() } }
    }
    var _jsonOom: Int64? {
        get { hasOom ? (oom) : nil }
        set { if let value = newValue { oom = value } else { clearOom() } }
    }
    var _jsonOomKill: Int64? {
        get { hasOomKill ? (oomKill) : nil }
        set { if let value = newValue { oomKill = value } else { clearOomKill() } }
    }
    var _jsonOomGroupKill: Int64? {
        get { hasOomGroupKill ? (oomGroupKill) : nil }
        set { if let value = newValue { oomGroupKill = value } else { clearOomGroupKill() } }
    }
}

/// Per-VM or per-sandbox contention observations. Every label needed to
/// attribute this sample (agent, workload id, and kind) lives outside this
/// value in the owning resource/report, so tenant-controlled names never enter
/// the telemetry cardinality surface.
public typealias WorkloadResourceTelemetry = Strato_Agent_V1_WorkloadResourceTelemetry
extension Strato_Agent_V1_WorkloadResourceTelemetry: Codable {
    /// Guest-reported cumulative steal time. It remains explicitly unavailable
    /// until a guest metrics source supplies a value; host CPU time is never
    /// substituted for it.

    public init(
        sampledAt: Date,
        health: ResourcePressureHealth,
        cgroupV2: ResourceTelemetryAvailability,
        memoryCurrentBytes: ResourceTelemetryValue,
        memoryEvents: WorkloadMemoryEventsTelemetry,
        memoryPressure: PressureStallTelemetry,
        cpuPressure: PressureStallTelemetry,
        ioPressure: PressureStallTelemetry,
        cpuUsageMicroseconds: ResourceTelemetryValue,
        cpuThrottledMicroseconds: ResourceTelemetryValue,
        cpuThrottledPeriodsTotal: ResourceTelemetryValue,
        guestStealMicroseconds: ResourceTelemetryValue = .unavailable
    ) {
        self.init()
        self._jsonSampledAt = sampledAt
        self._jsonHealth = health
        self._jsonCgroupV2 = cgroupV2
        self._jsonMemoryCurrentBytes = memoryCurrentBytes
        self._jsonMemoryEvents = memoryEvents
        self._jsonMemoryPressure = memoryPressure
        self._jsonCpuPressure = cpuPressure
        self._jsonIoPressure = ioPressure
        self._jsonCpuUsageMicroseconds = cpuUsageMicroseconds
        self._jsonCpuThrottledMicroseconds = cpuThrottledMicroseconds
        self._jsonCpuThrottledPeriodsTotal = cpuThrottledPeriodsTotal
        self._jsonGuestStealMicroseconds = guestStealMicroseconds
    }

    private enum CodingKeys: String, CodingKey {
        case sampledAt; case health; case cgroupV2; case memoryCurrentBytes; case memoryEvents; case memoryPressure;
        case cpuPressure; case ioPressure; case cpuUsageMicroseconds; case cpuThrottledMicroseconds;
        case cpuThrottledPeriodsTotal; case guestStealMicroseconds
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonSampledAt = try container.decode(Date.self, forKey: .sampledAt)
        self._jsonHealth = try container.decode(ResourcePressureHealth.self, forKey: .health)
        self._jsonCgroupV2 = try container.decode(ResourceTelemetryAvailability.self, forKey: .cgroupV2)
        self._jsonMemoryCurrentBytes = try container.decode(ResourceTelemetryValue.self, forKey: .memoryCurrentBytes)
        self._jsonMemoryEvents = try container.decode(WorkloadMemoryEventsTelemetry.self, forKey: .memoryEvents)
        self._jsonMemoryPressure = try container.decode(PressureStallTelemetry.self, forKey: .memoryPressure)
        self._jsonCpuPressure = try container.decode(PressureStallTelemetry.self, forKey: .cpuPressure)
        self._jsonIoPressure = try container.decode(PressureStallTelemetry.self, forKey: .ioPressure)
        self._jsonCpuUsageMicroseconds = try container.decode(
            ResourceTelemetryValue.self, forKey: .cpuUsageMicroseconds)
        self._jsonCpuThrottledMicroseconds = try container.decode(
            ResourceTelemetryValue.self, forKey: .cpuThrottledMicroseconds)
        self._jsonCpuThrottledPeriodsTotal = try container.decode(
            ResourceTelemetryValue.self, forKey: .cpuThrottledPeriodsTotal)
        self._jsonGuestStealMicroseconds = try container.decode(
            ResourceTelemetryValue.self, forKey: .guestStealMicroseconds)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonSampledAt, forKey: .sampledAt)
        try container.encode(_jsonHealth, forKey: .health)
        try container.encode(_jsonCgroupV2, forKey: .cgroupV2)
        try container.encode(_jsonMemoryCurrentBytes, forKey: .memoryCurrentBytes)
        try container.encode(_jsonMemoryEvents, forKey: .memoryEvents)
        try container.encode(_jsonMemoryPressure, forKey: .memoryPressure)
        try container.encode(_jsonCpuPressure, forKey: .cpuPressure)
        try container.encode(_jsonIoPressure, forKey: .ioPressure)
        try container.encode(_jsonCpuUsageMicroseconds, forKey: .cpuUsageMicroseconds)
        try container.encode(_jsonCpuThrottledMicroseconds, forKey: .cpuThrottledMicroseconds)
        try container.encode(_jsonCpuThrottledPeriodsTotal, forKey: .cpuThrottledPeriodsTotal)
        try container.encode(_jsonGuestStealMicroseconds, forKey: .guestStealMicroseconds)
    }

    var _jsonSampledAt: Date {
        get { sampledAt.date }
        set { let value = newValue; sampledAt = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonHealth: ResourcePressureHealth {
        get { health }
        set { let value = newValue; health = value }
    }
    var _jsonCgroupV2: ResourceTelemetryAvailability {
        get { cgroupV2 }
        set { let value = newValue; cgroupV2 = value }
    }
    var _jsonMemoryCurrentBytes: ResourceTelemetryValue {
        get { memoryCurrentBytes }
        set { let value = newValue; memoryCurrentBytes = value }
    }
    var _jsonMemoryEvents: WorkloadMemoryEventsTelemetry {
        get { memoryEvents }
        set { let value = newValue; memoryEvents = value }
    }
    var _jsonMemoryPressure: PressureStallTelemetry {
        get { memoryPressure }
        set { let value = newValue; memoryPressure = value }
    }
    var _jsonCpuPressure: PressureStallTelemetry {
        get { cpuPressure }
        set { let value = newValue; cpuPressure = value }
    }
    var _jsonIoPressure: PressureStallTelemetry {
        get { ioPressure }
        set { let value = newValue; ioPressure = value }
    }
    var _jsonCpuUsageMicroseconds: ResourceTelemetryValue {
        get { cpuUsageMicroseconds }
        set { let value = newValue; cpuUsageMicroseconds = value }
    }
    var _jsonCpuThrottledMicroseconds: ResourceTelemetryValue {
        get { cpuThrottledMicroseconds }
        set { let value = newValue; cpuThrottledMicroseconds = value }
    }
    var _jsonCpuThrottledPeriodsTotal: ResourceTelemetryValue {
        get { cpuThrottledPeriodsTotal }
        set { let value = newValue; cpuThrottledPeriodsTotal = value }
    }
    var _jsonGuestStealMicroseconds: ResourceTelemetryValue {
        get { guestStealMicroseconds }
        set { let value = newValue; guestStealMicroseconds = value }
    }
}
