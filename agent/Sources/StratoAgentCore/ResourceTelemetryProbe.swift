import Foundation
import StratoShared

/// One workload whose host-side isolation boundary may expose cgroup-v2
/// telemetry. A direct path is used for jailed Firecracker sandboxes; a PID
/// file lets libvirt QEMU domains resolve their actual unified cgroup without
/// depending on systemd's escaping convention.
public struct WorkloadTelemetryProbeTarget: Sendable, Equatable {
    public let workloadID: String
    public let kind: WorkloadKind
    public let directCgroupPath: String?
    public let pidFilePath: String?
    /// An independently supplied guest value. No guest source is configured
    /// today, so callers normally leave this explicitly unavailable.
    public let guestStealMicroseconds: ResourceTelemetryValue

    public init(
        workloadID: String,
        kind: WorkloadKind,
        directCgroupPath: String? = nil,
        pidFilePath: String? = nil,
        guestStealMicroseconds: ResourceTelemetryValue = .unavailable
    ) {
        self.workloadID = workloadID
        self.kind = kind
        self.directCgroupPath = directCgroupPath
        self.pidFilePath = pidFilePath
        self.guestStealMicroseconds = guestStealMicroseconds
    }
}

public struct ResourceTelemetrySnapshot: Sendable, Equatable {
    public let host: HostResourceTelemetry
    public let workloads: [String: WorkloadResourceTelemetry]

    public init(host: HostResourceTelemetry, workloads: [String: WorkloadResourceTelemetry]) {
        self.host = host
        self.workloads = workloads
    }
}

/// Synchronous Linux procfs/cgroup parsing, intended to run on a detached
/// utility task. It never shells out, waits on a daemon, or traverses an
/// unbounded tree: one fixed host file set plus a fixed file set per workload.
/// Injected readers make the parser deterministic on non-Linux test hosts.
public struct ResourceTelemetryProbe: Sendable {
    public typealias Read = @Sendable (String) -> String?
    public typealias ListDirectory = @Sendable (String) -> [String]?

    private let read: Read
    private let listDirectory: ListDirectory
    private let procRoot: String
    private let sysRoot: String

    public init(
        procRoot: String = "/proc",
        sysRoot: String = "/sys",
        read: @escaping Read,
        listDirectory: @escaping ListDirectory
    ) {
        self.procRoot = procRoot
        self.sysRoot = sysRoot
        self.read = read
        self.listDirectory = listDirectory
    }

    public static var live: Self {
        Self(
            read: { try? String(contentsOfFile: $0, encoding: .utf8) },
            listDirectory: { try? FileManager.default.contentsOfDirectory(atPath: $0) })
    }

    public func sample(
        targets: [WorkloadTelemetryProbeTarget],
        at sampledAt: Date = Date(),
        previousHost: HostResourceTelemetry? = nil
    ) -> ResourceTelemetrySnapshot {
        let host = sampleHost(at: sampledAt, previous: previousHost)
        var workloads: [String: WorkloadResourceTelemetry] = [:]
        for target in targets {
            workloads[target.workloadID] = sampleWorkload(target, at: sampledAt)
        }
        return ResourceTelemetrySnapshot(host: host, workloads: workloads)
    }

    // MARK: - Host

    private func sampleHost(at sampledAt: Date, previous: HostResourceTelemetry?) -> HostResourceTelemetry {
        let cpuPressure = pressure(at: "\(procRoot)/pressure/cpu")
        let memoryPressure = pressure(at: "\(procRoot)/pressure/memory")
        let ioPressure = pressure(at: "\(procRoot)/pressure/io")

        let meminfo = keyValues(read("\(procRoot)/meminfo"), separator: ":")
        let swapTotal = kibibyteValue(meminfo["SwapTotal"])
        let swapFree = kibibyteValue(meminfo["SwapFree"])
        let swapUsed: ResourceTelemetryValue
        if case .available = swapTotal.availability,
            case .available = swapFree.availability,
            let total = swapTotal.value,
            let free = swapFree.value
        {
            swapUsed = .available(max(0, total - free))
        } else {
            swapUsed = .unavailable
        }

        let vmstat = keyValues(read("\(procRoot)/vmstat"), separator: nil)
        let majorFaults = integerValue(vmstat["pgmajfault"])
        let oomKills = integerValue(vmstat["oom_kill"])
        let reclaimScanned = sumValues(vmstat, whoseKeyHasPrefix: "pgscan")
        let reclaimReclaimed = sumValues(vmstat, whoseKeyHasPrefix: "pgsteal")

        let mglruEnabled: ResourceTelemetryFlag
        if let raw = read("\(sysRoot)/kernel/mm/lru_gen/enabled")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let value = parseInteger(raw)
        {
            mglruEnabled = .available(value & 1 != 0)
        } else {
            mglruEnabled = .unavailable
        }

        let zramUsed = zramUsage()
        let elapsed = previous.map { sampledAt.timeIntervalSince($0.sampledAt) }
        func rate(_ current: ResourceTelemetryValue, _ prior: ResourceTelemetryValue?) -> Double? {
            guard let elapsed, elapsed > 0, let value = current.value,
                let old = prior?.value, value >= old
            else { return nil }
            return (Double(value) - Double(old)) / elapsed
        }
        let swapIn = integerValue(vmstat["pswpin"])
        let swapOut = integerValue(vmstat["pswpout"])
        let inRate = rate(swapIn, previous?.swapInPagesTotal)
        let outRate = rate(swapOut, previous?.swapOutPagesTotal)
        var warnings: [String] = []
        if (inRate ?? 0) > 0 && (outRate ?? 0) > 0 && (memoryPressure.full?.average10 ?? 0) >= 0.5 {
            warnings.append("swap_thrashing")
        }
        if let current = oomKills.value, let old = previous?.oomKillsTotal.value, current > old {
            warnings.append("oom_kill")
        }
        let health = Self.health(
            cpu: cpuPressure, memory: memoryPressure, io: ioPressure)
        return HostResourceTelemetry(
            sampledAt: sampledAt,
            health: health,
            cpuPressure: cpuPressure,
            memoryPressure: memoryPressure,
            ioPressure: ioPressure,
            swapTotalBytes: swapTotal,
            swapUsedBytes: swapUsed,
            zswapStoredBytes: kibibyteValue(meminfo["Zswapped"]),
            zswapPoolBytes: kibibyteValue(meminfo["Zswap"]),
            zramUsedBytes: zramUsed,
            majorFaultsTotal: majorFaults,
            reclaimScannedPagesTotal: reclaimScanned,
            reclaimReclaimedPagesTotal: reclaimReclaimed,
            oomKillsTotal: oomKills,
            mglruEnabled: mglruEnabled,
            memoryProfile: memoryProfileObservation(),
            swapInPagesTotal: integerValue(vmstat["pswpin"]),
            swapOutPagesTotal: integerValue(vmstat["pswpout"]),
            zramOriginalBytes: zramUsage(field: 0),
            swapInPagesPerSecond: inRate,
            swapOutPagesPerSecond: outRate,
            memoryWarnings: warnings)
    }

    private func zramUsage(field: Int = 2) -> ResourceTelemetryValue {
        guard let devices = listDirectory("\(sysRoot)/block")?.filter({ $0.hasPrefix("zram") }),
            !devices.isEmpty
        else { return .unavailable }

        var total: Int64 = 0
        var measured = false
        for device in devices {
            guard
                let line = read("\(sysRoot)/block/\(device)/mm_stat")?
                    .split(whereSeparator: \Character.isWhitespace),
                line.count >= 3,
                let used = Int64(line[field])
            else { continue }
            let result = total.addingReportingOverflow(used)
            total = result.overflow ? Int64.max : result.partialValue
            measured = true
        }
        return measured ? .available(total) : .unavailable
    }

    // MARK: - Workload

    private func sampleWorkload(
        _ target: WorkloadTelemetryProbeTarget, at sampledAt: Date
    ) -> WorkloadResourceTelemetry {
        guard let root = cgroupRoot(for: target) else {
            return unavailableWorkload(
                sampledAt: sampledAt, guestSteal: target.guestStealMicroseconds)
        }

        let memoryCurrent = integerValue(read("\(root)/memory.current"))
        let memoryEvents = parseMemoryEvents(read("\(root)/memory.events"))
        let memoryPressure = pressure(at: "\(root)/memory.pressure")
        let cpuPressure = pressure(at: "\(root)/cpu.pressure")
        let ioPressure = pressure(at: "\(root)/io.pressure")
        let cpuStat = keyValues(read("\(root)/cpu.stat"), separator: nil)
        let cpuUsage = integerValue(cpuStat["usage_usec"])
        let cpuThrottled = integerValue(cpuStat["throttled_usec"])
        let cpuThrottledPeriods = integerValue(cpuStat["nr_throttled"])

        let hasCgroupSignal = [
            memoryCurrent.availability,
            memoryEvents.availability,
            memoryPressure.availability,
            cpuPressure.availability,
            ioPressure.availability,
            cpuUsage.availability,
        ].contains(.available)
        let health = Self.health(
            cpu: cpuPressure, memory: memoryPressure, io: ioPressure)

        return WorkloadResourceTelemetry(
            sampledAt: sampledAt,
            health: hasCgroupSignal ? health : .unknown,
            cgroupV2: hasCgroupSignal ? .available : .unavailable,
            memoryCurrentBytes: memoryCurrent,
            memoryEvents: memoryEvents,
            memoryPressure: memoryPressure,
            cpuPressure: cpuPressure,
            ioPressure: ioPressure,
            cpuUsageMicroseconds: cpuUsage,
            cpuThrottledMicroseconds: cpuThrottled,
            cpuThrottledPeriodsTotal: cpuThrottledPeriods,
            guestStealMicroseconds: target.guestStealMicroseconds)
    }

    private func unavailableWorkload(
        sampledAt: Date, guestSteal: ResourceTelemetryValue
    ) -> WorkloadResourceTelemetry {
        WorkloadResourceTelemetry(
            sampledAt: sampledAt,
            health: .unknown,
            cgroupV2: .unavailable,
            memoryCurrentBytes: .unavailable,
            memoryEvents: .unavailable,
            memoryPressure: .unavailable,
            cpuPressure: .unavailable,
            ioPressure: .unavailable,
            cpuUsageMicroseconds: .unavailable,
            cpuThrottledMicroseconds: .unavailable,
            cpuThrottledPeriodsTotal: .unavailable,
            guestStealMicroseconds: guestSteal)
    }

    private func cgroupRoot(for target: WorkloadTelemetryProbeTarget) -> String? {
        if let direct = target.directCgroupPath,
            !direct.contains(".."),
            direct.hasPrefix("/")
        {
            return direct
        }
        guard let pidFilePath = target.pidFilePath,
            let pid = read(pidFilePath)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !pid.isEmpty, pid.allSatisfy(\.isNumber),
            let membership = read("\(procRoot)/\(pid)/cgroup")
        else { return nil }

        for line in membership.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "0", parts[1].isEmpty else { continue }
            let relative = String(parts[2])
            guard relative.hasPrefix("/"), !relative.contains("..") else { return nil }
            return "\(sysRoot)/fs/cgroup\(relative)"
        }
        return nil
    }

    // MARK: - Parsing

    static func health(
        cpu: PressureStallTelemetry,
        memory: PressureStallTelemetry,
        io: PressureStallTelemetry
    ) -> ResourcePressureHealth {
        let available = [cpu, memory, io].contains { $0.availability == .available }
        guard available else { return .unknown }

        let cpuSome = cpu.some?.average10 ?? 0
        let memorySome = memory.some?.average10 ?? 0
        let memoryFull = memory.full?.average10 ?? 0
        let ioSome = io.some?.average10 ?? 0
        let ioFull = io.full?.average10 ?? 0

        if cpuSome >= 50 || memorySome >= 20 || memoryFull >= 2 || ioSome >= 30 || ioFull >= 5 {
            return .critical
        }
        if cpuSome >= 10 || memorySome >= 5 || memoryFull >= 0.5 || ioSome >= 10 || ioFull >= 1 {
            return .pressured
        }
        return .healthy
    }

    private func pressure(at path: String) -> PressureStallTelemetry {
        guard let contents = read(path) else { return .unavailable }
        var some: PressureStallSample?
        var full: PressureStallSample?
        for line in contents.split(separator: "\n") {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard let kind = fields.first else { continue }
            var values: [String: String] = [:]
            for field in fields.dropFirst() {
                let pair = field.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                values[String(pair[0])] = String(pair[1])
            }
            guard let average10 = values["avg10"].flatMap(Double.init),
                let average60 = values["avg60"].flatMap(Double.init),
                let average300 = values["avg300"].flatMap(Double.init),
                let total = values["total"].flatMap(Int64.init)
            else { continue }
            let sample = PressureStallSample(
                average10: average10, average60: average60,
                average300: average300, totalMicroseconds: total)
            if kind == "some" { some = sample }
            if kind == "full" { full = sample }
        }
        guard some != nil || full != nil else { return .unavailable }
        return .available(some: some, full: full)
    }

    private func keyValues(_ contents: String?, separator: Character?) -> [String: String] {
        guard let contents else { return [:] }
        var values: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let parts: [Substring]
            if let separator {
                parts = line.split(separator: separator, maxSplits: 1)
            } else {
                parts = line.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
            }
            guard parts.count == 2 else { continue }
            values[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    private func parseMemoryEvents(_ contents: String?) -> WorkloadMemoryEventsTelemetry {
        guard let contents else { return .unavailable }
        let values = keyValues(contents, separator: nil)
        guard !values.isEmpty else { return .unavailable }
        return WorkloadMemoryEventsTelemetry(
            availability: .available,
            low: values["low"].flatMap(Int64.init),
            high: values["high"].flatMap(Int64.init),
            max: values["max"].flatMap(Int64.init),
            oom: values["oom"].flatMap(Int64.init),
            oomKill: values["oom_kill"].flatMap(Int64.init),
            oomGroupKill: values["oom_group_kill"].flatMap(Int64.init))
    }

    private func kibibyteValue(_ raw: String?) -> ResourceTelemetryValue {
        guard let raw,
            let first = raw.split(whereSeparator: \Character.isWhitespace).first,
            let kibibytes = Int64(first)
        else { return .unavailable }
        let (bytes, overflow) = kibibytes.multipliedReportingOverflow(by: 1024)
        return .available(overflow ? Int64.max : bytes)
    }

    private func integerValue(_ raw: String?) -> ResourceTelemetryValue {
        guard let raw,
            let first = raw.split(whereSeparator: \Character.isWhitespace).first,
            let value = Int64(first)
        else { return .unavailable }
        return .available(value)
    }

    private func sumValues(
        _ values: [String: String], whoseKeyHasPrefix prefix: String
    ) -> ResourceTelemetryValue {
        let matching = values.filter { $0.key.hasPrefix(prefix) }.compactMap { Int64($0.value) }
        guard !matching.isEmpty else { return .unavailable }
        var total: Int64 = 0
        for value in matching {
            let result = total.addingReportingOverflow(value)
            total = result.overflow ? Int64.max : result.partialValue
        }
        return .available(total)
    }

    private func parseInteger(_ raw: String) -> Int64? {
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            return Int64(raw.dropFirst(2), radix: 16)
        }
        return Int64(raw)
    }
}

extension ResourceTelemetryProbe {
    public func memoryProfileObservation() -> HostMemoryProfileObservation? {
        guard let raw = read("/etc/strato/host-memory-profile.json") else {
            // A rollback interrupted while KSM pages are unmerging must remain visible.
            guard read("/var/lib/strato/host-memory-profile.json") != nil else { return nil }
            return HostMemoryProfileObservation(
                configured: nil, effectiveTier: nil, thpPolicy: nil,
                ksmRunning: nil, reason: "profile_rollback_pending")
        }
        let config = try? JSONDecoder().decode(HostMemoryProfileConfiguration.self, from: Data(raw.utf8))
        let thp = read("\(sysRoot)/kernel/mm/transparent_hugepage/enabled")?
            .split(separator: " ").first { $0.hasPrefix("[") }?
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]\n"))
        let ksmRun = read("\(sysRoot)/kernel/mm/ksm/run").flatMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let enabled = read("\(sysRoot)/module/zswap/parameters/enabled")?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let swaps =
            read("\(procRoot)/swaps")?.split(separator: "\n").dropFirst().map {
                $0.split(whereSeparator: \.isWhitespace)
            } ?? []
        let zramActive = swaps.contains { $0.first == "/dev/zram0" && $0.count >= 5 && Int($0[4]) == 100 }
        let effective: HostMemoryProfileConfiguration.Tier? =
            enabled == "Y" || enabled == "1" ? .zswap : (zramActive ? .zram : nil)
        var reason: String?
        if let config {
            if thp == nil {
                reason = "thp_unsupported"
            } else if ksmRun == nil {
                reason = "ksm_unsupported"
            } else if enabled == nil && config.tier == .zswap {
                reason = "zswap_unsupported"
            } else if config.ksm == true && config.tenantClass != .single {
                reason = "ksm_multitenant_forbidden"
            } else if effective != config.tier {
                reason = "compressed_tier_inactive"
            } else if !swaps.contains(where: { $0.first.map(String.init) == config.nvmeSwap }) {
                reason = "nvme_fallback_inactive"
            } else if thp != "madvise" {
                reason = "thp_madvise_inactive"
            } else if ksmRun == 2 {
                reason = "ksm_unmerge_pending_no_hostile_placement"
            } else if config.ksm == true && ksmRun != 1 {
                reason = "ksm_scanner_inactive"
            } else if config.ksm != true {
                let shared = read("\(sysRoot)/kernel/mm/ksm/pages_shared").flatMap {
                    Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let sharing = read("\(sysRoot)/kernel/mm/ksm/pages_sharing").flatMap {
                    Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if ksmRun != 0 || shared != 0 || sharing != 0 { reason = "ksm_unmerge_pending_no_hostile_placement" }
            }
            if reason == nil && config.tier == .zram {
                let size = read("\(sysRoot)/block/zram0/disksize").flatMap {
                    Int64($0.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if size != (config.zramBytes ?? 1_073_741_824) { reason = "zram_size_mismatch_or_unsupported" }
                if swaps.contains(where: { $0.first != "/dev/zram0" && $0.count >= 5 && (Int($0[4]) ?? 100) >= 100 }) {
                    reason = "operator_swap_priority_conflict"
                }
            }
            if reason == nil && config.tier == .zswap {
                let pool = read("\(sysRoot)/module/zswap/parameters/max_pool_percent").flatMap {
                    Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if pool != (config.zswapPoolPercent ?? 20) { reason = "zswap_pool_mismatch_or_unsupported" }
            }
            if reason == nil && config.ksm == true {
                let pages = read("\(sysRoot)/kernel/mm/ksm/pages_to_scan").flatMap {
                    Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let sleep = read("\(sysRoot)/kernel/mm/ksm/sleep_millisecs").flatMap {
                    Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if pages != (config.ksmPagesToScan ?? 100) || sleep != (config.ksmSleepMilliseconds ?? 100)
                    || !(1...1000).contains(pages ?? 0) || !(50...60000).contains(sleep ?? 0)
                {
                    reason = "ksm_scanner_bounds_mismatch"
                }
            }
            if reason == nil && config.requireMGLRU == true {
                if let raw = read("\(sysRoot)/kernel/mm/lru_gen/enabled")?.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                    let bits = parseInteger(raw), bits & 1 != 0
                {
                } else {
                    reason = "mglru_disabled_or_unsupported"
                }
            }
        } else {
            reason = "invalid_memory_profile"
        }
        return HostMemoryProfileObservation(
            configured: config, effectiveTier: effective, thpPolicy: thp,
            ksmRunning: ksmRun.map { $0 == 1 }, reason: reason)
    }
}
