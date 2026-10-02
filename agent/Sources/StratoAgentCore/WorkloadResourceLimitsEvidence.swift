import Foundation
import StratoShared

/// Local runtime evidence pending coordinated STR-266/267 wire allocation.
/// This is not a parallel class model: desire and target use the canonical
/// shared runtime limits. Matching file values alone never acknowledge ownership.
public struct WorkloadResourceLimitsEvidence: Codable, Sendable, Equatable {
    public let desired: WorkloadRuntimeLimits
    public let ownedCgroupPath: String?
    public let alignedTarget: WorkloadRuntimeLimits?
    public let appliedMemoryHighBytes: ResourceTelemetryValue
    public let appliedMemoryMaxBytes: ResourceTelemetryValue
    public let memoryHighUnlimited: ResourceTelemetryFlag
    public let memoryMaxUnlimited: ResourceTelemetryFlag
    public let appliedCPUWeight: ResourceTelemetryValue
    public let cpuQuotaUnlimited: ResourceTelemetryFlag
    public let ownershipVerified: ResourceTelemetryFlag
    public let controlsMatchTarget: ResourceTelemetryFlag
    public let enforcementAcknowledged: ResourceTelemetryFlag

    public static func sample(
        limits: BurstableResourceLimits, ownedPath: String?, pageSize: Int64,
        ownershipVerified: Bool? = nil,
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> Self {
        let target = try? limits.desired.aligned(pageSizeBytes: pageSize)
        let path = ownedPath.flatMap {
            BurstableCgroupReadback.sample(ownedPath: $0, readFile: readFile) == nil ? nil : $0
        }
        func raw(_ field: String) -> String? {
            path.flatMap { readFile($0 + "/" + field)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        func value(_ field: String) -> ResourceTelemetryValue {
            guard let text = raw(field), let number = Int64(text), number >= 0 else { return .unavailable }
            return .available(number)
        }
        func unlimited(_ field: String) -> ResourceTelemetryFlag {
            guard let text = raw(field) else { return .unavailable }
            if text == "max" { return .available(true) }
            guard let number = Int64(text), number >= 0 else { return .unavailable }
            return .available(false)
        }
        let high = value("memory.high")
        let maximum = value("memory.max")
        let weight = value("cpu.weight")
        let highUnlimited = unlimited("memory.high")
        let maximumUnlimited = unlimited("memory.max")
        let quota = path.flatMap {
            BurstableCgroupReadback.sample(ownedPath: $0, readFile: readFile)?.cpuQuotaUnlimited
        }
        let quotaFlag = quota.map(ResourceTelemetryFlag.available) ?? .unavailable
        let ownershipFlag = ownershipVerified.map(ResourceTelemetryFlag.available) ?? .unavailable
        let match: ResourceTelemetryFlag
        if target != nil, highUnlimited.value == true || maximumUnlimited.value == true || quota == false {
            match = .available(false)
        } else if let target, let appliedHigh = high.value, let appliedMax = maximum.value,
            let appliedWeight = weight.value,
            highUnlimited.value == false, maximumUnlimited.value == false, quota == true
        {
            match = .available(
                appliedHigh == target.memoryHighBytes && appliedMax == target.memoryMaxBytes
                    && appliedWeight == Int64(target.cpuWeight))
        } else {
            match = .unavailable
        }
        let acknowledged: ResourceTelemetryFlag
        if ownershipVerified == false || match.value == false {
            acknowledged = .available(false)
        } else if ownershipVerified == true, match.value == true {
            acknowledged = .available(true)
        } else {
            acknowledged = .unavailable
        }
        return Self(
            desired: limits.desired, ownedCgroupPath: ownershipVerified == true ? path : nil, alignedTarget: target,
            appliedMemoryHighBytes: high, appliedMemoryMaxBytes: maximum,
            memoryHighUnlimited: highUnlimited, memoryMaxUnlimited: maximumUnlimited,
            appliedCPUWeight: weight, cpuQuotaUnlimited: quotaFlag, ownershipVerified: ownershipFlag,
            controlsMatchTarget: match, enforcementAcknowledged: acknowledged)
    }
}
