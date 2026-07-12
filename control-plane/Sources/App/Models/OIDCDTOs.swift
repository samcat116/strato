import Fluent
import Vapor
@preconcurrency import JWT
import Crypto
import Foundation

// OIDC data-transfer objects and JWT/JWKS crypto types, relocated out of
// OIDCController to keep the controller focused on request handling.

// MARK: - OIDC Discovery Document

struct OIDCDiscoveryDocument: Content {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let userinfoEndpoint: String?
    let endSessionEndpoint: String?
    let jwksURI: String
    let responseTypesSupported: [String]
    let subjectTypesSupported: [String]
    let idTokenSigningAlgValuesSupported: [String]

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case userinfoEndpoint = "userinfo_endpoint"
        case endSessionEndpoint = "end_session_endpoint"
        case jwksURI = "jwks_uri"
        case responseTypesSupported = "response_types_supported"
        case subjectTypesSupported = "subject_types_supported"
        case idTokenSigningAlgValuesSupported = "id_token_signing_alg_values_supported"
    }
}

// MARK: - OIDC Authentication Data Structures

/// The token endpoint response. Any `refresh_token` the IdP returns is
/// deliberately ignored: the Vapor session is the sole credential lifetime —
/// the control plane never calls IdP APIs after login completes, so a
/// persisted refresh token would be a stored credential with no consumer.
struct OIDCTokenResponse: Content {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int?
    let idToken: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case idToken = "id_token"
    }
}

struct OIDCIDTokenClaims: Content, JWTPayload, @unchecked Sendable {
    let iss: String  // Issuer
    let sub: String  // Subject
    let aud: String  // Audience
    let exp: ExpirationClaim  // Expiration time
    let iat: IssuedAtClaim  // Issued at
    let nonce: String?
    let email: String?
    let emailVerified: Bool?
    let name: String?
    let preferredUsername: String?

    func verify(using signer: JWTSigner) throws {
        try self.exp.verifyNotExpired()
        // iat verification happens automatically
    }

    private enum CodingKeys: String, CodingKey {
        case iss, sub, aud, exp, iat, nonce, email, name
        case emailVerified = "email_verified"
        case preferredUsername = "preferred_username"
    }
}

/// The subset of the OIDC UserInfo endpoint response we consult. Fetched to
/// recover claims that IdPs omit from the ID token: `email_verified`, and the
/// profile claims for providers like Discord whose ID token carries only
/// `sub`. `sub` is required so the caller can enforce the OIDC 5.3.2 rule that
/// the UserInfo subject must match the ID token subject before trusting any of
/// its claims.
struct OIDCUserInfoResponse: Content {
    let sub: String
    let email: String?
    let emailVerified: Bool?
    let name: String?
    let preferredUsername: String?
    let nickname: String?

    private enum CodingKeys: String, CodingKey {
        case sub, email, name, nickname
        case emailVerified = "email_verified"
        case preferredUsername = "preferred_username"
    }
}

struct OIDCUserInfo {
    let subject: String
    let email: String?
    /// Whether the IdP asserts the email is verified. Only a verified email may
    /// be used to link an OIDC identity to an existing account (see
    /// `OIDCIdentityService.resolveUser`); an unverified/attacker-asserted email
    /// must not match a victim's account.
    let emailVerified: Bool
    let name: String?
    let preferredUsername: String?
    /// Values of the provider's configured groups claim (empty when the
    /// provider has no groups claim configured or the token omits it).
    var groupValues: [String] = []
}

// MARK: - JWT Header

/// The decoded JOSE header of an ID token, parsed to pin the signature
/// algorithm (see `OIDCTokenVerification.requireAllowedAlgorithm`) before
/// JWTKit verifies the signature. All fields optional: `typ` is commonly
/// omitted by IdPs, and a missing `alg` is rejected by the allow-list check
/// rather than as a decode failure. Key material itself is handled by JWTKit's
/// JWK/JWKS types.
struct JWTHeader: Codable {
    let alg: String?
    let typ: String?
    let kid: String?
}
