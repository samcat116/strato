import Foundation
import StratoShared

// MARK: - JWS decoding

/// Decoding of a JWT-SVID's *unverified* registered claims (issue #495).
///
/// The Workload API hands back a JWT-SVID as a bare compact-serialized token
/// with no expiry field alongside it, so rotation timing has to come out of the
/// token itself. Everything here reads the payload **without checking the
/// signature** — legitimate only because the local SPIRE agent already vouched
/// for the token it just minted for us.
///
/// A relying party must never use this: verifying a JWT-SVID means checking the
/// signature against the trust domain's JWT authorities and the audience
/// against its own name. That path lives in the control plane
/// (`JWTSVIDVerification`), not here.
public enum JWTSVIDToken {

    /// The registered claims a JWT-SVID carries (RFC 7519 + the SPIFFE
    /// JWT-SVID profile, which makes `sub`, `aud` and `exp` mandatory).
    public struct Claims: Sendable, Equatable {
        /// The SPIFFE ID the token names, from `sub`.
        public let subject: String
        /// The audiences the token was minted for, from `aud`.
        public let audience: [String]
        public let expiresAt: Date
        public let issuedAt: Date?
        public let notBefore: Date?

        public init(
            subject: String,
            audience: [String],
            expiresAt: Date,
            issuedAt: Date? = nil,
            notBefore: Date? = nil
        ) {
            self.subject = subject
            self.audience = audience
            self.expiresAt = expiresAt
            self.issuedAt = issuedAt
            self.notBefore = notBefore
        }
    }

    /// Decode the registered claims of a compact-serialized JWS **without
    /// verifying its signature**.
    ///
    /// - Throws: `SPIFFEError.parseError` when the token is not three
    ///   base64url segments, the payload is not JSON, or a claim the SPIFFE
    ///   JWT-SVID profile requires (`sub`, `aud`, `exp`) is missing.
    public static func decodeUnverifiedClaims(_ token: String) throws -> Claims {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else {
            throw SPIFFEError.parseError(
                "JWT-SVID is not a compact-serialized JWS (expected 3 segments, got \(segments.count))")
        }

        guard let payloadData = Base64URL.decode(String(segments[1])) else {
            throw SPIFFEError.parseError("JWT-SVID payload is not valid base64url")
        }

        let payload: RegisteredClaims
        do {
            payload = try JSONDecoder().decode(RegisteredClaims.self, from: payloadData)
        } catch {
            throw SPIFFEError.parseError("JWT-SVID payload is not a JSON claims set: \(error)")
        }

        guard let subject = payload.sub, !subject.isEmpty else {
            throw SPIFFEError.parseError("JWT-SVID has no 'sub' claim")
        }
        guard let expiry = payload.exp else {
            throw SPIFFEError.parseError("JWT-SVID has no 'exp' claim")
        }
        guard !payload.aud.isEmpty else {
            throw SPIFFEError.parseError("JWT-SVID has no 'aud' claim")
        }

        return Claims(
            subject: subject,
            audience: payload.aud,
            expiresAt: Date(timeIntervalSince1970: expiry),
            issuedAt: payload.iat.map { Date(timeIntervalSince1970: $0) },
            notBefore: payload.nbf.map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// Whether a token looks like a compact-serialized JWS — three non-empty
    /// base64url segments. A shape test only: it says a bearer credential
    /// should be routed to JWT-SVID verification, never that it is valid.
    public static func hasCompactJWSShape(_ token: String) -> Bool {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty
                && segment.allSatisfy { character in
                    character.isLetter || character.isNumber || character == "-" || character == "_"
                }
        }
    }

    /// The registered claims, with `aud` accepting both JWT spellings: a single
    /// string, or an array of them (RFC 7519 §4.1.3).
    private struct RegisteredClaims: Decodable {
        let sub: String?
        let aud: [String]
        let exp: TimeInterval?
        let iat: TimeInterval?
        let nbf: TimeInterval?

        private enum CodingKeys: String, CodingKey {
            case sub, aud, exp, iat, nbf
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sub = try container.decodeIfPresent(String.self, forKey: .sub)
            exp = try container.decodeIfPresent(TimeInterval.self, forKey: .exp)
            iat = try container.decodeIfPresent(TimeInterval.self, forKey: .iat)
            nbf = try container.decodeIfPresent(TimeInterval.self, forKey: .nbf)

            if let single = try? container.decodeIfPresent(String.self, forKey: .aud) {
                aud = [single]
            } else {
                aud = try container.decodeIfPresent([String].self, forKey: .aud) ?? []
            }
        }
    }
}
