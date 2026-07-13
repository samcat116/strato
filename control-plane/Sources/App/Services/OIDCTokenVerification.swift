import Foundation
import JWT
import Vapor

/// ID-token signature verification helpers for the OIDC login flow.
///
/// Verification is delegated to JWTKit's JWKS support, which selects the key by
/// the token header's `kid` and constructs a verifier only when the header's
/// `alg` is compatible with the key's type — an RSA key can never satisfy an
/// `ES256` header and a public JWK can never yield an HMAC verifier, which
/// closes the classic algorithm-confusion holes of trusting `alg` alone.
/// Supported algorithms: RS256/RS384/RS512, ES256/ES384/ES512, and EdDSA.
enum OIDCTokenVerification {
    /// JWS algorithms accepted in an ID token header. All are asymmetric:
    /// `none` and the HMAC family are rejected outright, since an HMAC
    /// "signature" would be forgeable by anyone holding the (public) JWKS.
    static let allowedAlgorithms: Set<String> = [
        "RS256", "RS384", "RS512", "ES256", "ES384", "ES512", "EdDSA",
    ]

    /// Rejects tokens whose header names a missing or non-allow-listed
    /// algorithm before any signature work happens.
    static func requireAllowedAlgorithm(_ header: IDTokenHeader) throws {
        guard let alg = header.alg, allowedAlgorithms.contains(alg) else {
            throw Abort(
                .badRequest,
                reason: "Unsupported ID token signature algorithm '\(header.alg ?? "<missing>")'")
        }
    }

    /// Builds JWT verifiers from a provider's raw JWKS document.
    ///
    /// Keys are decoded individually and unusable ones skipped — real-world
    /// JWKS documents mix in encryption keys (`use: "enc"`) and key types
    /// JWTKit doesn't model (e.g. secp256k1), and a strict whole-document
    /// decode would turn one exotic key into a login outage for the provider.
    /// Throws only when the document is malformed or yields no usable key.
    static func makeVerifiers(jwksJSON: Data, logger: Logger? = nil) async throws -> OIDCTokenVerifiers {
        guard let root = try? JSONSerialization.jsonObject(with: jwksJSON) as? [String: Any],
            let rawKeys = root["keys"] as? [Any]
        else {
            throw Abort(.badGateway, reason: "Provider JWKS document is malformed")
        }

        let keys = JWTKeyCollection()
        let decoder = JSONDecoder()
        var registered = 0
        var knownKeyIDs: Set<String> = []
        for rawKey in rawKeys {
            guard let keyObject = rawKey as? [String: Any] else { continue }
            // Keys published for encryption are not signature keys.
            if let use = keyObject["use"] as? String, use != "sig" { continue }
            guard let keyData = try? JSONSerialization.data(withJSONObject: keyObject),
                var jwk = try? decoder.decode(JWK.self, from: keyData)
            else {
                logger?.debug(
                    "Skipping unsupported key in provider JWKS",
                    metadata: ["kty": .string(keyObject["kty"] as? String ?? "<missing>")])
                continue
            }
            // JWTKit refuses keys without a `kid`. Some single-key IdPs omit it,
            // so synthesize one: the first registered key doubles as the default
            // signer, which is what verifies tokens whose header carries no kid.
            if jwk.keyIdentifier == nil {
                jwk.keyIdentifier = JWKIdentifier(string: "strato-unnamed-key-\(registered)")
            }
            do {
                try await keys.add(jwk: jwk)
                registered += 1
                if let kid = jwk.keyIdentifier?.string {
                    knownKeyIDs.insert(kid)
                }
            } catch {
                logger?.debug(
                    "Skipping unusable key in provider JWKS",
                    metadata: ["kid": .string(jwk.keyIdentifier?.string ?? "<missing>")])
            }
        }

        guard registered > 0 else {
            throw Abort(.badGateway, reason: "Provider JWKS contained no usable signing keys")
        }
        return OIDCTokenVerifiers(keys: keys, knownKeyIDs: knownKeyIDs)
    }
}

/// A provider's registered verification keys plus the set of `kid`s they were
/// registered under. The kid set exists to close a JWTKit fallback: its lookup
/// silently uses the default (first) key when a token names a `kid` missing
/// from the set, which would accept tokens pointing at unknown or rotated
/// keys. Tokens naming an unknown `kid` are rejected outright instead.
struct OIDCTokenVerifiers {
    let keys: JWTKeyCollection
    let knownKeyIDs: Set<String>

    /// Verifies the token's signature and decodes its claims. A token whose
    /// header names a `kid` absent from the JWKS is rejected before any
    /// signature work; a kid-less token uses the default (first) key, the
    /// standard behavior for single-key providers.
    func verify(_ idToken: String, header: IDTokenHeader) async throws -> OIDCIDTokenClaims {
        if let kid = header.kid, !knownKeyIDs.contains(kid) {
            throw Abort(
                .badRequest,
                reason: "ID token references a signing key ('\(kid)') not present in the provider's JWKS")
        }
        return try await keys.verify(idToken, as: OIDCIDTokenClaims.self)
    }
}
