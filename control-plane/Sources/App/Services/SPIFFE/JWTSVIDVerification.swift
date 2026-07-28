import Foundation
import JWT
import Vapor

// JWT-SVIDs as short-lived programmatic credentials (issue #495).
//
// A JWT-SVID is a bearer token: unlike an X.509 SVID it survives hops that
// cannot carry a client certificate (load balancers, TLS-terminating ingress),
// which is what makes it usable for automation and CI. That same property is
// why verification here is strict and why the token's reach is deliberately
// narrow:
//
//   - the signature must chain to the trust domain's *current* JWT authorities,
//   - the audience must name this control plane exactly, so a token minted for
//     another relying party cannot be replayed here,
//   - and the `sub` SPIFFE ID is used **only as a lookup key** into
//     `workload_registrations`. No claim in the token grants anything
//     (docs/architecture/iam.md: "identity names the principal; it never
//     carries authorization").

/// The registered claims of a JWT-SVID (the SPIFFE JWT-SVID profile requires
/// `sub`, `aud` and `exp`; `iat`/`nbf` are optional and honored when present).
///
/// Deliberately nothing else: any additional claim SPIRE or an operator adds is
/// ignored rather than parsed, because reading one would be the first step
/// toward trusting it.
struct JWTSVIDClaims: Content, JWTPayload {
    let sub: String
    let aud: OIDCAudienceClaim
    let exp: ExpirationClaim
    let iat: IssuedAtClaim?
    let nbf: NotBeforeClaim?

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try self.exp.verifyNotExpired()
        try self.nbf?.verifyNotBefore()
    }

    private enum CodingKeys: String, CodingKey {
        case sub, aud, exp, iat, nbf
    }
}

/// A verified JWT-SVID: the identity the token names, and when it expires.
struct VerifiedJWTSVID: Sendable, Equatable {
    let spiffeID: SPIFFEIdentity
    let expiresAt: Date
}

/// Errors from JWT-SVID verification. Distinguished from a plain `Abort` so the
/// authenticator can tell "this is not a JWT-SVID at all" (fall through to the
/// other bearer authenticators) from "this is a JWT-SVID and it is bad".
enum JWTSVIDVerificationError: Error, CustomStringConvertible {
    /// No JWT authorities are loaded for the trust domain, so nothing can be
    /// verified against it. Fails closed.
    case noAuthorities(trustDomain: String)
    case malformed(String)
    case rejected(String)

    var description: String {
        switch self {
        case .noAuthorities(let trustDomain):
            return "No JWT authorities are available for trust domain '\(trustDomain)'"
        case .malformed(let reason):
            return "Malformed JWT-SVID: \(reason)"
        case .rejected(let reason):
            return "JWT-SVID rejected: \(reason)"
        }
    }
}

/// Verification of JWT-SVIDs presented as bearer credentials.
///
/// Mirrors `OIDCTokenVerification`, which solves the same problem for ID
/// tokens: JWTKit selects the key by the header's `kid` and only builds a
/// verifier when the header's `alg` is compatible with that key's type, which
/// is what closes the algorithm-confusion holes of trusting `alg` alone.
enum JWTSVIDVerification {

    /// JWS algorithms accepted in a JWT-SVID header. All asymmetric: `none` and
    /// the HMAC family are rejected outright, since an HMAC "signature" would
    /// be forgeable by anyone holding the (public) JWKS.
    ///
    /// The SPIFFE JWT-SVID specification names this same set.
    static let allowedAlgorithms: Set<String> = [
        "RS256", "RS384", "RS512", "ES256", "ES384", "ES512", "PS256", "PS384", "PS512", "EdDSA",
    ]

    /// Decode the JOSE header, rejecting anything the profile disallows before
    /// any signature work happens.
    static func decodeHeader(_ token: String) throws -> IDTokenHeader {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else {
            throw JWTSVIDVerificationError.malformed("expected 3 JWS segments, got \(segments.count)")
        }
        guard let headerData = JWTSVIDVerification.base64URLDecode(String(segments[0])) else {
            throw JWTSVIDVerificationError.malformed("header is not valid base64url")
        }
        guard let header = try? JSONDecoder().decode(IDTokenHeader.self, from: headerData) else {
            throw JWTSVIDVerificationError.malformed("header is not a JSON object")
        }
        guard let alg = header.alg, allowedAlgorithms.contains(alg) else {
            throw JWTSVIDVerificationError.rejected(
                "unsupported signature algorithm '\(header.alg ?? "<missing>")'")
        }
        // The profile requires `typ`, when present, to be JWT or JOSE. A token
        // typed as something else was minted for a different protocol.
        if let typ = header.typ, typ != "JWT", typ != "JOSE" {
            throw JWTSVIDVerificationError.rejected("unsupported token type '\(typ)'")
        }
        return header
    }

    /// Build verifiers from a trust domain's JWKS document.
    ///
    /// Keys that JWTKit cannot model are skipped rather than failing the whole
    /// document — one exotic key must not take down every workload's
    /// authentication — but a document yielding no usable key throws, because
    /// "no keys" can never mean "accept".
    static func makeVerifiers(jwksJSON: Data, logger: Logger? = nil) async throws -> JWTSVIDVerifiers {
        guard let root = try? JSONSerialization.jsonObject(with: jwksJSON) as? [String: Any],
            let rawKeys = root["keys"] as? [Any]
        else {
            throw JWTSVIDVerificationError.malformed("trust domain JWKS document is malformed")
        }

        let keys = JWTKeyCollection()
        let decoder = JSONDecoder()
        var knownKeyIDs: Set<String> = []
        for rawKey in rawKeys {
            guard var keyObject = rawKey as? [String: Any] else { continue }
            // SPIFFE bundles mark JWT signing keys `use: "jwt-svid"` and X.509
            // roots `use: "x509-svid"`. Only the former are signing keys here,
            // and JWTKit expects the JOSE spelling — so select on the SPIFFE
            // value and hand JWTKit the JOSE one. A key with no `use` at all is
            // taken as a signing key (a plain JWKS, e.g. from FetchJWTBundles).
            if let use = keyObject["use"] as? String {
                guard use == "jwt-svid" || use == "sig" else { continue }
                keyObject["use"] = "sig"
            }
            guard let keyData = try? JSONSerialization.data(withJSONObject: keyObject),
                let jwk = try? decoder.decode(JWK.self, from: keyData),
                let kid = jwk.keyIdentifier?.string
            else {
                logger?.debug(
                    "Skipping unusable key in trust domain JWKS",
                    metadata: ["kty": .string(keyObject["kty"] as? String ?? "<missing>")])
                continue
            }
            do {
                try await keys.add(jwk: jwk)
                knownKeyIDs.insert(kid)
            } catch {
                logger?.debug(
                    "Skipping unregisterable key in trust domain JWKS",
                    metadata: ["kid": .string(kid)])
            }
        }

        guard !knownKeyIDs.isEmpty else {
            throw JWTSVIDVerificationError.malformed("trust domain JWKS contained no usable signing keys")
        }
        return JWTSVIDVerifiers(keys: keys, knownKeyIDs: knownKeyIDs)
    }

    /// Decode one base64url segment (RFC 7515 §2).
    static func base64URLDecode(_ segment: String) -> Data? {
        var base64 =
            segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        return Data(base64Encoded: base64)
    }

    /// Whether a bearer credential looks like a compact-serialized JWS, so it
    /// should be routed to JWT-SVID verification rather than to the API-key or
    /// CLI-token authenticators. A shape test only — never a validity claim.
    static func hasCompactJWSShape(_ token: String) -> Bool {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty
                && segment.allSatisfy { character in
                    character.isLetter || character.isNumber || character == "-" || character == "_"
                }
        }
    }
}

/// A trust domain's registered verification keys plus the `kid`s they were
/// registered under.
///
/// The kid set closes a JWTKit fallback: its lookup silently uses the default
/// (first) key when a token names a `kid` missing from the collection, which
/// would accept tokens pointing at unknown or already-rotated keys. Here a
/// JWT-SVID must always name a known `kid` — SPIRE always sets one, so unlike
/// the OIDC path there is no kid-less single-key case to accommodate.
struct JWTSVIDVerifiers {
    let keys: JWTKeyCollection
    let knownKeyIDs: Set<String>

    /// Verify a token's signature and claims, returning the identity it names.
    ///
    /// - Parameters:
    ///   - token: the compact-serialized JWT-SVID.
    ///   - header: its already-decoded and algorithm-checked header.
    ///   - audience: this control plane's audience name. The token must name it
    ///     exactly; a token minted for a different relying party is rejected
    ///     even though its signature is perfectly good.
    ///   - trustDomain: the domain whose authorities are in `keys`. The `sub`
    ///     must belong to it, so a bundle can never verify an identity from
    ///     another domain.
    func verify(
        _ token: String,
        header: IDTokenHeader,
        audience: String,
        trustDomain: String
    ) async throws -> VerifiedJWTSVID {
        guard let kid = header.kid else {
            throw JWTSVIDVerificationError.rejected("token header carries no key id")
        }
        guard knownKeyIDs.contains(kid) else {
            throw JWTSVIDVerificationError.rejected(
                "token references a signing key ('\(kid)') not in the trust domain's JWT authorities")
        }

        let claims: JWTSVIDClaims
        do {
            claims = try await keys.verify(token, as: JWTSVIDClaims.self)
        } catch {
            throw JWTSVIDVerificationError.rejected("signature or claim verification failed")
        }

        guard claims.aud.values.contains(audience) else {
            throw JWTSVIDVerificationError.rejected(
                "token audience does not include this control plane ('\(audience)')")
        }

        guard let spiffeID = SPIFFEIdentity(uri: claims.sub) else {
            throw JWTSVIDVerificationError.rejected("subject '\(claims.sub)' is not a SPIFFE ID")
        }
        guard spiffeID.trustDomain == trustDomain else {
            throw JWTSVIDVerificationError.rejected(
                "subject belongs to trust domain '\(spiffeID.trustDomain)', not '\(trustDomain)'")
        }

        return VerifiedJWTSVID(spiffeID: spiffeID, expiresAt: claims.exp.value)
    }
}
