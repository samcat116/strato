import Foundation

/// Operator bootstrap intent, never a desired-state instruction or API mutation.
public struct HostMemoryProfileConfiguration: Codable, Sendable, Equatable {
    public enum Tier: String, Codable, CaseIterable, Sendable { case zswap, zram }
    public enum TenantClass: String, Codable, Sendable { case single, multi }

    public let tier: Tier
    public let tenantClass: TenantClass
    public let nvmeSwap: String
    public let zramBytes: Int64?
    public let zswapPoolPercent: Int?
    public let ksm: Bool?
    public let requireMGLRU: Bool?
    public let ksmPagesToScan: Int?
    public let ksmSleepMilliseconds: Int?

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
}

/// Live read-only evidence. Absence and configured/effective mismatch are failures,
/// including the interval between disabling KSM and completion of unmerging.
public struct HostMemoryProfileObservation: Codable, Sendable, Equatable {
    public let configured: HostMemoryProfileConfiguration?
    public let effectiveTier: HostMemoryProfileConfiguration.Tier?
    public let thpPolicy: String?
    public let ksmRunning: Bool?
    public let reason: String?

    public init(
        configured: HostMemoryProfileConfiguration?,
        effectiveTier: HostMemoryProfileConfiguration.Tier?,
        thpPolicy: String?, ksmRunning: Bool?, reason: String?
    ) {
        self.configured = configured
        self.effectiveTier = effectiveTier
        self.thpPolicy = thpPolicy
        self.ksmRunning = ksmRunning
        self.reason = reason
    }
}
