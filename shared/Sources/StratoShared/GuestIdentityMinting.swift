import Foundation

/// Bounds shared by every guest JWT-SVID entry point. Keeping these beside the
/// wire model prevents the agent from accepting a request the control plane
/// will refuse after the policy has already advertised it to the guest.
public enum GuestIdentityLimits {
    public static let maximumAudiencesPerRequest = 8
    public static let maximumAudienceCharacters = 255
    public static let maximumMetadataRequestTargetBytes = 2 * 1024
    public static let metadataIdentityPath = "/strato/v1/identity"

    public static func isValidAudience(_ audience: String) -> Bool {
        guard
            !audience.isEmpty,
            audience.count <= maximumAudienceCharacters,
            audience.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }

        // The listener accepts only an ASCII request target, so every Unicode
        // audience needs an encoded representation that fits its target bound.
        // Encode punctuation too: this canonical form cannot accidentally add
        // query delimiters or the `..` sequence rejected by the path parser.
        let unescaped = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~")
        guard let encoded = audience.addingPercentEncoding(withAllowedCharacters: unescaped) else {
            return false
        }
        let prefix = "\(metadataIdentityPath)?audience="
        return prefix.utf8.count + encoded.utf8.count <= maximumMetadataRequestTargetBytes
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
