import Foundation
import SwiftProtobuf

/// Operator bootstrap intent, never a desired-state instruction or API mutation.
public typealias HostMemoryProfileConfiguration = Strato_Agent_V1_HostMemoryProfileConfiguration
extension Strato_Agent_V1_HostMemoryProfileConfiguration: Codable {
    public typealias Tier = Strato_Agent_V1_HostMemoryTier
    public typealias TenantClass = Strato_Agent_V1_HostMemoryTenantClass

    enum CodingKeys: String, CodingKey {
        case tier, ksm
        case zramBytes = "zram_bytes"
        case zswapPoolPercent = "zswap_pool_percent"
        case tenantClass = "tenant_class"
        case nvmeSwap = "nvme_swap"
        case requireMGLRU = "require_mglru"
        case ksmPagesToScan = "ksm_pages_to_scan"
        case ksmSleepMilliseconds = "ksm_sleep_millisecs"
    }

    public init(
        tier: Tier, tenantClass: TenantClass, nvmeSwap: String, zramBytes: Int64? = nil, zswapPoolPercent: Int? = nil,
        ksm: Bool? = nil, requireMGLRU: Bool? = nil, ksmPagesToScan: Int? = nil, ksmSleepMilliseconds: Int? = nil
    ) {
        self.init()
        self._jsonTier = tier
        self._jsonTenantClass = tenantClass
        self._jsonNvmeSwap = nvmeSwap
        self._jsonZramBytes = zramBytes
        self._jsonZswapPoolPercent = zswapPoolPercent
        self._jsonKsm = ksm
        self._jsonRequireMGLRU = requireMGLRU
        self._jsonKsmPagesToScan = ksmPagesToScan
        self._jsonKsmSleepMilliseconds = ksmSleepMilliseconds
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonTier = try container.decode(Tier.self, forKey: .tier)
        self._jsonTenantClass = try container.decode(TenantClass.self, forKey: .tenantClass)
        self._jsonNvmeSwap = try container.decode(String.self, forKey: .nvmeSwap)
        self._jsonZramBytes = try container.decodeIfPresent(Int64.self, forKey: .zramBytes)
        self._jsonZswapPoolPercent = try container.decodeIfPresent(Int.self, forKey: .zswapPoolPercent)
        self._jsonKsm = try container.decodeIfPresent(Bool.self, forKey: .ksm)
        self._jsonRequireMGLRU = try container.decodeIfPresent(Bool.self, forKey: .requireMGLRU)
        self._jsonKsmPagesToScan = try container.decodeIfPresent(Int.self, forKey: .ksmPagesToScan)
        self._jsonKsmSleepMilliseconds = try container.decodeIfPresent(Int.self, forKey: .ksmSleepMilliseconds)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonTier, forKey: .tier)
        try container.encode(_jsonTenantClass, forKey: .tenantClass)
        try container.encode(_jsonNvmeSwap, forKey: .nvmeSwap)
        try container.encodeIfPresent(_jsonZramBytes, forKey: .zramBytes)
        try container.encodeIfPresent(_jsonZswapPoolPercent, forKey: .zswapPoolPercent)
        try container.encodeIfPresent(_jsonKsm, forKey: .ksm)
        try container.encodeIfPresent(_jsonRequireMGLRU, forKey: .requireMGLRU)
        try container.encodeIfPresent(_jsonKsmPagesToScan, forKey: .ksmPagesToScan)
        try container.encodeIfPresent(_jsonKsmSleepMilliseconds, forKey: .ksmSleepMilliseconds)
    }

    var _jsonTier: Tier {
        get { tier }
        set { let value = newValue; tier = value }
    }
    var _jsonTenantClass: TenantClass {
        get { tenantClass }
        set { let value = newValue; tenantClass = value }
    }
    var _jsonNvmeSwap: String {
        get { nvmeSwap }
        set { let value = newValue; nvmeSwap = value }
    }
    var _jsonZramBytes: Int64? {
        get { hasZramBytes ? (zramBytes) : nil }
        set { if let value = newValue { zramBytes = value } else { clearZramBytes() } }
    }
    var _jsonZswapPoolPercent: Int? {
        get { hasZswapPoolPercent ? (Int(zswapPoolPercent)) : nil }
        set { if let value = newValue { zswapPoolPercent = Int64(value) } else { clearZswapPoolPercent() } }
    }
    var _jsonKsm: Bool? {
        get { hasKsm ? (ksm) : nil }
        set { if let value = newValue { ksm = value } else { clearKsm() } }
    }
    var _jsonRequireMGLRU: Bool? {
        get { hasRequireMglru ? (requireMglru) : nil }
        set { if let value = newValue { requireMglru = value } else { clearRequireMglru() } }
    }
    var _jsonKsmPagesToScan: Int? {
        get { hasKsmPagesToScan ? (Int(ksmPagesToScan)) : nil }
        set { if let value = newValue { ksmPagesToScan = Int64(value) } else { clearKsmPagesToScan() } }
    }
    var _jsonKsmSleepMilliseconds: Int? {
        get { hasKsmSleepMilliseconds ? (Int(ksmSleepMilliseconds)) : nil }
        set { if let value = newValue { ksmSleepMilliseconds = Int64(value) } else { clearKsmSleepMilliseconds() } }
    }
}

/// Live read-only evidence. Absence and configured/effective mismatch are failures,
/// including the interval between disabling KSM and completion of unmerging.
public typealias HostMemoryProfileObservation = Strato_Agent_V1_HostMemoryProfileObservation
extension Strato_Agent_V1_HostMemoryProfileObservation: Codable {

    public init(
        configured: HostMemoryProfileConfiguration?,
        effectiveTier: HostMemoryProfileConfiguration.Tier?,
        thpPolicy: String?, ksmRunning: Bool?, reason: String?
    ) {
        self.init()
        self._jsonConfigured = configured
        self._jsonEffectiveTier = effectiveTier
        self._jsonThpPolicy = thpPolicy
        self._jsonKsmRunning = ksmRunning
        self._jsonReason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case configured; case effectiveTier; case thpPolicy; case ksmRunning; case reason
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonConfigured = try container.decodeIfPresent(HostMemoryProfileConfiguration.self, forKey: .configured)
        self._jsonEffectiveTier = try container.decodeIfPresent(
            HostMemoryProfileConfiguration.Tier.self, forKey: .effectiveTier)
        self._jsonThpPolicy = try container.decodeIfPresent(String.self, forKey: .thpPolicy)
        self._jsonKsmRunning = try container.decodeIfPresent(Bool.self, forKey: .ksmRunning)
        self._jsonReason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(_jsonConfigured, forKey: .configured)
        try container.encodeIfPresent(_jsonEffectiveTier, forKey: .effectiveTier)
        try container.encodeIfPresent(_jsonThpPolicy, forKey: .thpPolicy)
        try container.encodeIfPresent(_jsonKsmRunning, forKey: .ksmRunning)
        try container.encodeIfPresent(_jsonReason, forKey: .reason)
    }

    var _jsonConfigured: HostMemoryProfileConfiguration? {
        get { hasConfigured ? (configured) : nil }
        set { if let value = newValue { configured = value } else { clearConfigured() } }
    }
    var _jsonEffectiveTier: HostMemoryProfileConfiguration.Tier? {
        get { hasEffectiveTier ? (effectiveTier) : nil }
        set { if let value = newValue { effectiveTier = value } else { clearEffectiveTier() } }
    }
    var _jsonThpPolicy: String? {
        get { hasThpPolicy ? (thpPolicy) : nil }
        set { if let value = newValue { thpPolicy = value } else { clearThpPolicy() } }
    }
    var _jsonKsmRunning: Bool? {
        get { hasKsmRunning ? (ksmRunning) : nil }
        set { if let value = newValue { ksmRunning = value } else { clearKsmRunning() } }
    }
    var _jsonReason: String? {
        get { hasReason ? (reason) : nil }
        set { if let value = newValue { reason = value } else { clearReason() } }
    }
}
