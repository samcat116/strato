import Foundation

/// Whether a resource signal was measured in the latest sampling pass.
///
/// Availability is part of every scalar signal so an unsupported kernel,
/// backend, or guest source cannot be mistaken for a measured zero. A failed
/// read is also unavailable: the next independent sampling pass retries it.
public enum ResourceTelemetryAvailability: String, Codable, Sendable, Equatable {
    case available
    case unavailable
}

/// An integer resource signal together with explicit availability.
///
/// Counters (faults, reclaim, CPU time) and gauges (bytes) share this wire
/// shape. Their names document their temporality; keeping one representation
/// makes absence handling identical everywhere.
public struct ResourceTelemetryValue: Codable, Sendable, Equatable {
    public let availability: ResourceTelemetryAvailability
    public let value: Int64?

    public init(availability: ResourceTelemetryAvailability, value: Int64? = nil) {
        self.availability = availability
        self.value = availability == .available ? value : nil
    }

    public static func available(_ value: Int64) -> Self {
        Self(availability: .available, value: value)
    }

    public static let unavailable = Self(availability: .unavailable)
}

/// A boolean capability or state with explicit availability.
public struct ResourceTelemetryFlag: Codable, Sendable, Equatable {
    public let availability: ResourceTelemetryAvailability
    public let value: Bool?

    public init(availability: ResourceTelemetryAvailability, value: Bool? = nil) {
        self.availability = availability
        self.value = availability == .available ? value : nil
    }

    public static func available(_ value: Bool) -> Self {
        Self(availability: .available, value: value)
    }

    public static let unavailable = Self(availability: .unavailable)
}

/// One Linux PSI `some` or `full` line.
public struct PressureStallSample: Codable, Sendable, Equatable {
    /// Percentage of wall time stalled over the last 10, 60, and 300 seconds.
    public let average10: Double
    public let average60: Double
    public let average300: Double
    /// Cumulative stalled time since boot/cgroup creation, in microseconds.
    public let totalMicroseconds: Int64

    public init(
        average10: Double,
        average60: Double,
        average300: Double,
        totalMicroseconds: Int64
    ) {
        self.average10 = average10
        self.average60 = average60
        self.average300 = average300
        self.totalMicroseconds = totalMicroseconds
    }
}

/// One PSI resource file. `full` is independently optional because CPU PSI
/// and older kernels may expose only `some` while still providing a valid
/// signal. A measured all-zero line remains present and distinct from absence.
public struct PressureStallTelemetry: Codable, Sendable, Equatable {
    public let availability: ResourceTelemetryAvailability
    public let some: PressureStallSample?
    public let full: PressureStallSample?

    public init(
        availability: ResourceTelemetryAvailability,
        some: PressureStallSample? = nil,
        full: PressureStallSample? = nil
    ) {
        self.availability = availability
        self.some = availability == .available ? some : nil
        self.full = availability == .available ? full : nil
    }

    public static func available(
        some: PressureStallSample?, full: PressureStallSample?
    ) -> Self {
        Self(availability: .available, some: some, full: full)
    }

    public static let unavailable = Self(availability: .unavailable)
}

/// Operator-facing pressure summary. Raw signals remain the alert authority;
/// this bounded state is the compact field later placement policy can consume.
public enum ResourcePressureHealth: String, Codable, Sendable, Equatable {
    case unknown
    case healthy
    case pressured
    case critical
}

/// Host-wide pressure, reclaim, swap, and OOM observations.
public struct HostResourceTelemetry: Codable, Sendable, Equatable {
    public let sampledAt: Date
    public let health: ResourcePressureHealth
    public let cpuPressure: PressureStallTelemetry
    public let memoryPressure: PressureStallTelemetry
    public let ioPressure: PressureStallTelemetry
    public let swapTotalBytes: ResourceTelemetryValue
    public let swapUsedBytes: ResourceTelemetryValue
    /// Bytes of original pages currently represented in zswap.
    public let zswapStoredBytes: ResourceTelemetryValue
    /// Bytes currently consumed by zswap's compressed pool.
    public let zswapPoolBytes: ResourceTelemetryValue
    /// Sum of `mem_used_total` across the host's zram block devices.
    public let zramUsedBytes: ResourceTelemetryValue
    public let majorFaultsTotal: ResourceTelemetryValue
    public let reclaimScannedPagesTotal: ResourceTelemetryValue
    public let reclaimReclaimedPagesTotal: ResourceTelemetryValue
    public let oomKillsTotal: ResourceTelemetryValue
    /// Available false means the kernel exposes MGLRU but it is disabled;
    /// unavailable means this kernel exposes no MGLRU control at all.
    public let mglruEnabled: ResourceTelemetryFlag

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
        mglruEnabled: ResourceTelemetryFlag
    ) {
        self.sampledAt = sampledAt
        self.health = health
        self.cpuPressure = cpuPressure
        self.memoryPressure = memoryPressure
        self.ioPressure = ioPressure
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.zswapStoredBytes = zswapStoredBytes
        self.zswapPoolBytes = zswapPoolBytes
        self.zramUsedBytes = zramUsedBytes
        self.majorFaultsTotal = majorFaultsTotal
        self.reclaimScannedPagesTotal = reclaimScannedPagesTotal
        self.reclaimReclaimedPagesTotal = reclaimReclaimedPagesTotal
        self.oomKillsTotal = oomKillsTotal
        self.mglruEnabled = mglruEnabled
    }
}

/// Monotonic counters from cgroup v2 `memory.events`.
public struct WorkloadMemoryEventsTelemetry: Codable, Sendable, Equatable {
    public let availability: ResourceTelemetryAvailability
    public let low: Int64?
    public let high: Int64?
    public let max: Int64?
    public let oom: Int64?
    public let oomKill: Int64?
    public let oomGroupKill: Int64?

    public init(
        availability: ResourceTelemetryAvailability,
        low: Int64? = nil,
        high: Int64? = nil,
        max: Int64? = nil,
        oom: Int64? = nil,
        oomKill: Int64? = nil,
        oomGroupKill: Int64? = nil
    ) {
        self.availability = availability
        self.low = availability == .available ? low : nil
        self.high = availability == .available ? high : nil
        self.max = availability == .available ? max : nil
        self.oom = availability == .available ? oom : nil
        self.oomKill = availability == .available ? oomKill : nil
        self.oomGroupKill = availability == .available ? oomGroupKill : nil
    }

    public static let unavailable = Self(availability: .unavailable)
}

/// Per-VM or per-sandbox contention observations. Every label needed to
/// attribute this sample (agent, workload id, and kind) lives outside this
/// value in the owning resource/report, so tenant-controlled names never enter
/// the telemetry cardinality surface.
public struct WorkloadResourceTelemetry: Codable, Sendable, Equatable {
    public let sampledAt: Date
    public let health: ResourcePressureHealth
    public let cgroupV2: ResourceTelemetryAvailability
    public let memoryCurrentBytes: ResourceTelemetryValue
    public let memoryEvents: WorkloadMemoryEventsTelemetry
    public let memoryPressure: PressureStallTelemetry
    public let cpuPressure: PressureStallTelemetry
    public let ioPressure: PressureStallTelemetry
    public let cpuUsageMicroseconds: ResourceTelemetryValue
    public let cpuThrottledMicroseconds: ResourceTelemetryValue
    public let cpuThrottledPeriodsTotal: ResourceTelemetryValue
    /// Guest-reported cumulative steal time. It remains explicitly unavailable
    /// until a guest metrics source supplies a value; host CPU time is never
    /// substituted for it.
    public let guestStealMicroseconds: ResourceTelemetryValue

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
        self.sampledAt = sampledAt
        self.health = health
        self.cgroupV2 = cgroupV2
        self.memoryCurrentBytes = memoryCurrentBytes
        self.memoryEvents = memoryEvents
        self.memoryPressure = memoryPressure
        self.cpuPressure = cpuPressure
        self.ioPressure = ioPressure
        self.cpuUsageMicroseconds = cpuUsageMicroseconds
        self.cpuThrottledMicroseconds = cpuThrottledMicroseconds
        self.cpuThrottledPeriodsTotal = cpuThrottledPeriodsTotal
        self.guestStealMicroseconds = guestStealMicroseconds
    }
}
