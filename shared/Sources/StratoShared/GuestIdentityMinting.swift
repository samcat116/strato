import Foundation

/// Bounds shared by every guest JWT-SVID entry point. Keeping these beside the
/// wire model prevents the agent from accepting a request the control plane
/// will refuse after the policy has already advertised it to the guest.
public enum GuestIdentityLimits {
    public static let maximumAudiencesPerRequest = 8
    public static let maximumAudienceCharacters = 255

    public static func isValidAudience(_ audience: String) -> Bool {
        !audience.isEmpty && audience.count <= maximumAudienceCharacters
    }
}

/// The guest identity document an agent asks the control plane to mint for a
/// VM it currently hosts.
public struct GuestJWTSVIDRequest: Codable, Sendable, Equatable {
    public let audiences: [String]
    public let ttlSeconds: Int?

    public init(audiences: [String], ttlSeconds: Int? = nil) {
        self.audiences = audiences
        self.ttlSeconds = ttlSeconds
    }
}

/// A JWT-SVID minted for a guest VM, including the effective policy values the
/// agent must use for caching rather than re-deriving them from its request.
public struct GuestJWTSVIDResponse: Codable, Sendable, Equatable {
    public let token: String
    public let spiffeId: String
    public let audiences: [String]
    public let expiresAt: Date
    public let issuedAt: Date?

    public init(
        token: String,
        spiffeId: String,
        audiences: [String],
        expiresAt: Date,
        issuedAt: Date? = nil
    ) {
        self.token = token
        self.spiffeId = spiffeId
        self.audiences = audiences
        self.expiresAt = expiresAt
        self.issuedAt = issuedAt
    }
}
