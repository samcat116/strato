import Foundation
import StratoShared
import Vapor

/// Policy for control-plane issuance of guest JWT-SVIDs (STR-57).
///
/// An empty audience allowlist disables issuance. This is deliberately the
/// default: enabling a new bearer-credential surface requires an operator to
/// name every relying party that may receive a guest identity.
struct GuestIdentityIssuanceConfig: Sendable, Equatable {
    let allowedAudiences: Set<String>
    let defaultTTLSeconds: Int
    let maximumTTLSeconds: Int

    static let disabled = GuestIdentityIssuanceConfig(
        allowedAudiences: [], defaultTTLSeconds: 300, maximumTTLSeconds: 3600)

    static func fromEnvironment() throws -> Self {
        try GuestIdentityIssuanceConfig(
            allowedAudiences: audiences(rawValue: Environment.get("GUEST_IDENTITY_AUDIENCES")),
            defaultTTLSeconds: ttlSeconds(
                rawValue: Environment.get("GUEST_IDENTITY_JWT_TTL"), fallback: 300),
            maximumTTLSeconds: ttlSeconds(
                rawValue: Environment.get("GUEST_IDENTITY_JWT_MAX_TTL"), fallback: 3600)
        )
    }

    /// Pure parsing for a comma-separated allowlist. Keeping environment reads
    /// out of this function lets concurrent suites exercise every edge without
    /// racing through process-global `setenv`.
    static func audiences(rawValue: String?) throws -> Set<String> {
        guard let rawValue else { return [] }
        let audiences = Set(
            rawValue.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        guard audiences.allSatisfy(GuestIdentityLimits.isValidAudience) else {
            throw GuestIdentityIssuanceConfigurationError.audienceTooLong
        }
        return audiences
    }

    /// Parse a strictly positive TTL, falling back for absent or unusable
    /// values. The controller separately validates caller-supplied TTLs so it
    /// can report a stable refusal reason.
    static func ttlSeconds(rawValue: String?, fallback: Int) -> Int {
        guard
            let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            let value = Int(rawValue), value > 0
        else { return fallback }
        return value
    }

    func permits(audiences: [String]) -> Bool {
        audiences.allSatisfy(allowedAudiences.contains)
    }

    func resolvedTTL(requested: Int?) -> Int32 {
        let maximum = max(1, maximumTTLSeconds)
        let resolved = min(max(1, requested ?? defaultTTLSeconds), maximum)
        return Int32(clamping: resolved)
    }
}

extension Application {
    private struct GuestIdentityIssuanceConfigKey: StorageKey {
        typealias Value = GuestIdentityIssuanceConfig
    }

    var guestIdentityIssuanceConfig: GuestIdentityIssuanceConfig {
        get { storage[GuestIdentityIssuanceConfigKey.self] ?? .disabled }
        set { setStorageValue(GuestIdentityIssuanceConfigKey.self, to: newValue) }
    }

    func configureGuestIdentityIssuance() throws {
        guestIdentityIssuanceConfig = try .fromEnvironment()
    }
}

enum GuestIdentityIssuanceConfigurationError: Error, LocalizedError {
    case audienceTooLong

    var errorDescription: String? {
        switch self {
        case .audienceTooLong:
            return "GUEST_IDENTITY_AUDIENCES entries must contain at most "
                + "\(GuestIdentityLimits.maximumAudienceCharacters) characters"
        }
    }
}
