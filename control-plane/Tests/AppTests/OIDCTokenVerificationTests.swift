import Crypto
import Foundation
import Testing
import Vapor
@preconcurrency import JWT

@testable import App

@Suite("OIDCTokenVerification Tests")
struct OIDCTokenVerificationTests {

    // MARK: - Fixtures

    /// Fixed 2048-bit RSA test key (generated for these tests only). The
    /// modulus below is its public `n` in base64url; `e` is the standard AQAB.
    private static let rsaPrivatePEM = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAw53lKeH32+wtvZlQXsm6XwA5pojXbUXA9SQFl2gq2mHdU/s+
        zNTu0KR2OiuPI0dhw5HQoBUeErNBBfkyyG7vCdH2xaPQJpJN2cQjTgKIzWQK0Bmb
        f4L1bKAJJLC6WWdwPcHpXIYlZOj1lH/MHqM0AJNBHKKAYf/+t0UPm6mgIXZx/BPM
        DdQKBtgADZOwnc2pp1lAt6kulpG8Oki20Z1ozj+O9/RQmUmUgNqaAfybhn9THyWa
        ZLEcwH4SXg/epWUicV/7CXhu5iaf7RFO/JgE51KkzWymnNYl3peDbUSw2jaLdZxF
        h7L8uMuwZ8LnS7c2nhiKLR6It4PLloEtU7ZNoQIDAQABAoIBAQCoMrjcBWdYm0BN
        OWlox23Px+LKNfl+BK9AWWPRZwkJ04I6dtrtxt09W1wo8lFWVUdToKpRKzc7fxQW
        7cnjm7c/q2DTWeJdeAkmiMaOihFVAYNmoc4ZmuIqL4UNHkRtIUraX0SngNTgaorW
        z/gUE+Jf6D3hQDzBhxtePCyKfRSqD6pgo5xgA3tqFxPnN3GcPx70311KMwW6zzDX
        Hl4k3QUV/p8FGTWVfg9ud+Cym0pQxAC7gyOVzNq56+ViLCaK/DYI9iAzN/41JzYW
        SJPlCx5G5BpAiMAv5NpU/agzNmsk363xcpZBAO/8WgOH3DZPRDQiWVo6wgDX49+k
        5eF0d8rRAoGBAPfxnaWkYRINKxWIZnX09QTtVAmpB03zeS/2BsbvKsUmMefUz4jy
        AWD63PAk7prJFPzD2cdut10qJO33kb8/HE9HhgrZ3p5z3ndT/5QRa3G5iChQ0Rik
        4gGaW8wG5eZI+N8vbB7bAtGM0lzm5yz28YotzNCkrS73OYhFlRnpQnjdAoGBAMn5
        BpWIxf5lfJHsFQQXS7hZAjh0LfgIuN2lz+A7qDSamAkl8z62RVbsmxAAIqx2m4IM
        ZQ4g6Lbm9clRgHWCuE3ne4oZgxoh6Rry2moRxWAvJcfkcP4uX6B+i/Lap0k/DPNa
        R3eErpnzTPLpYRS5g65KJ842RfeZ4XWI8rKnY/mVAoGASRuZHEpHxQbU+VhqvcUo
        qfdAnEiWuslbpmSowueqeM82T+FUAFE7TtkpZDW/lSxNX+pvwHpI3tOaaABjnTyC
        oG26fGCZX6dSpWTDK2mngLTwDNMnlFipu0dEYfh2uVwy5bwZ6U8ymY8oR/RdnciC
        l/fBOJQV7I9BC4lY2XcJ/pECgYApE9XL+epS6C8iuoI3t8k1sBysgKyMwrFemweh
        UmDOehar3aUQPx/xIuQSqARlUSYlmAHBkt3hvS2GCWZ3/+MeLRNKLhAk83qmeXgE
        lKKxAkXL1uFIQQQ/7xzlgqT9V655nAXm//xG4V3oFaEiBu0KOJjJ7u3iAtEBB55c
        yYCi1QKBgCDOHYaGfMMSAdVUEDv2F+ieMMjpO72xbu6djLNRcRPhDmVnoaMHuFQi
        +dWKKz1gSKGOGfTNX6/LJj8jQukwgwHgq+bF3v+ybkV2j1ulQenRNZ2DAShcaP0L
        nshkzfZqcwQE4dzCXLmiX1nUBw0w+laK/dk8pi0tTpYCzb37+e8P
        -----END RSA PRIVATE KEY-----
        """

    private static let rsaModulus =
        "w53lKeH32-wtvZlQXsm6XwA5pojXbUXA9SQFl2gq2mHdU_s-zNTu0KR2OiuPI0dhw5HQoBUeErNBBfkyyG7vCdH2xaPQJpJN2cQjTgKIzWQK0Bmbf4L1bKAJJLC6WWdwPcHpXIYlZOj1lH_MHqM0AJNBHKKAYf_-t0UPm6mgIXZx_BPMDdQKBtgADZOwnc2pp1lAt6kulpG8Oki20Z1ozj-O9_RQmUmUgNqaAfybhn9THyWaZLEcwH4SXg_epWUicV_7CXhu5iaf7RFO_JgE51KkzWymnNYl3peDbUSw2jaLdZxFh7L8uMuwZ8LnS7c2nhiKLR6It4PLloEtU7ZNoQ"

    private func makeClaims() -> OIDCIDTokenClaims {
        OIDCIDTokenClaims(
            iss: "https://idp.example.com",
            sub: "user-123",
            aud: "client-abc",
            exp: ExpirationClaim(value: Date().addingTimeInterval(3600)),
            iat: IssuedAtClaim(value: Date()),
            nonce: nil,
            email: "user@example.com",
            emailVerified: true,
            name: "Test User",
            preferredUsername: nil
        )
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func jwksJSON(keys: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["keys": keys])
    }

    private func rsaJWK(kid: String = "rsa-key", use: String? = nil) -> [String: Any] {
        var jwk: [String: Any] = [
            "kty": "RSA", "alg": "RS256", "kid": kid,
            "n": Self.rsaModulus, "e": "AQAB",
        ]
        if let use { jwk["use"] = use }
        return jwk
    }

    // MARK: - Algorithm allow-list

    @Test("Allow-list accepts asymmetric algorithms and rejects the rest")
    func testAlgorithmAllowList() throws {
        for alg in ["RS256", "RS384", "RS512", "ES256", "ES384", "ES512", "EdDSA"] {
            try OIDCTokenVerification.requireAllowedAlgorithm(JWTHeader(alg: alg, typ: "JWT", kid: nil))
        }
        for alg in ["HS256", "HS384", "HS512", "none", "NONE", "rs256"] {
            #expect(throws: (any Error).self) {
                try OIDCTokenVerification.requireAllowedAlgorithm(JWTHeader(alg: alg, typ: "JWT", kid: nil))
            }
        }
        // A header with no alg at all is rejected too.
        #expect(throws: (any Error).self) {
            try OIDCTokenVerification.requireAllowedAlgorithm(JWTHeader(alg: nil, typ: nil, kid: nil))
        }
    }

    // MARK: - Signature verification per algorithm

    @Test("RS256-signed token verifies against an RSA JWK")
    func testRS256() throws {
        let signingKey = try RSAKey.private(pem: Self.rsaPrivatePEM)
        let signer = JWTSigners()
        signer.use(.rs256(key: signingKey), kid: "rsa-key")
        let token = try signer.sign(makeClaims(), kid: "rsa-key")

        let verifiers = try OIDCTokenVerification.makeVerifiers(jwksJSON: jwksJSON(keys: [rsaJWK()]))
        let claims = try verifiers.verify(token, header: JWTHeader(alg: "RS256", typ: "JWT", kid: "rsa-key"))
        #expect(claims.sub == "user-123")
    }

    @Test("ES256-signed token verifies against an EC JWK")
    func testES256() throws {
        let key = try ECDSAKey.generate(curve: .p256)
        let parameters = try #require(key.parameters)
        let signer = JWTSigners()
        signer.use(.es256(key: key), kid: "ec-key")
        let token = try signer.sign(makeClaims(), kid: "ec-key")

        let jwks = try jwksJSON(keys: [
            [
                "kty": "EC", "alg": "ES256", "kid": "ec-key", "crv": "P-256",
                "x": parameters.x, "y": parameters.y,
            ]
        ])
        let verifiers = try OIDCTokenVerification.makeVerifiers(jwksJSON: jwks)
        let claims = try verifiers.verify(token, header: JWTHeader(alg: "ES256", typ: "JWT", kid: "ec-key"))
        #expect(claims.sub == "user-123")
    }

    @Test("EdDSA-signed token verifies against an OKP JWK")
    func testEdDSA() throws {
        let raw = Curve25519.Signing.PrivateKey()
        let x = base64URL(raw.publicKey.rawRepresentation)
        let d = base64URL(raw.rawRepresentation)
        let key = try EdDSAKey.private(x: x, d: d, curve: .ed25519)
        let signer = JWTSigners()
        signer.use(.eddsa(key), kid: "ed-key")
        let token = try signer.sign(makeClaims(), kid: "ed-key")

        let jwks = try jwksJSON(keys: [
            ["kty": "OKP", "alg": "EdDSA", "kid": "ed-key", "crv": "Ed25519", "x": x]
        ])
        let verifiers = try OIDCTokenVerification.makeVerifiers(jwksJSON: jwks)
        let claims = try verifiers.verify(token, header: JWTHeader(alg: "EdDSA", typ: "JWT", kid: "ed-key"))
        #expect(claims.sub == "user-123")
    }

    // MARK: - Algorithm confusion

    @Test("Token claiming ES256 under an RSA key's kid is rejected")
    func testAlgorithmConfusionRejected() throws {
        // The attacker signs with their own EC key but points the header at
        // the provider's RSA key. The header `alg` must not steer an RSA key
        // into EC verification.
        let attackerKey = try ECDSAKey.generate(curve: .p256)
        let attackerSigner = JWTSigners()
        attackerSigner.use(.es256(key: attackerKey), kid: "rsa-key")
        let forged = try attackerSigner.sign(makeClaims(), kid: "rsa-key")

        let verifiers = try OIDCTokenVerification.makeVerifiers(jwksJSON: jwksJSON(keys: [rsaJWK()]))
        #expect(throws: (any Error).self) {
            try verifiers.verify(forged, header: JWTHeader(alg: "ES256", typ: "JWT", kid: "rsa-key"))
        }
    }

    @Test("RS256 token whose kid resolves to a key of a different type is rejected")
    func testMismatchedKeyTypeRejected() throws {
        let signingKey = try RSAKey.private(pem: Self.rsaPrivatePEM)
        let signer = JWTSigners()
        signer.use(.rs256(key: signingKey), kid: "rsa-key")
        let token = try signer.sign(makeClaims(), kid: "rsa-key")

        // Same kid, different key material (an EC key published under the kid
        // the token names).
        let otherKey = try ECDSAKey.generate(curve: .p256)
        let parameters = try #require(otherKey.parameters)
        let jwks = try jwksJSON(keys: [
            [
                "kty": "EC", "alg": "ES256", "kid": "rsa-key", "crv": "P-256",
                "x": parameters.x, "y": parameters.y,
            ]
        ])
        let verifiers = try OIDCTokenVerification.makeVerifiers(jwksJSON: jwks)
        #expect(throws: (any Error).self) {
            try verifiers.verify(token, header: JWTHeader(alg: "RS256", typ: "JWT", kid: "rsa-key"))
        }
    }

    @Test("Token naming a kid absent from the JWKS is rejected, not defaulted")
    func testUnknownKidRejected() throws {
        // Even a token signed by the provider's real key must be rejected when
        // its header names a kid the JWKS doesn't publish — JWTKit alone would
        // silently fall back to the default (first) key here.
        let signingKey = try RSAKey.private(pem: Self.rsaPrivatePEM)
        let signer = JWTSigners()
        signer.use(.rs256(key: signingKey), kid: "rotated-away")
        let token = try signer.sign(makeClaims(), kid: "rotated-away")

        let verifiers = try OIDCTokenVerification.makeVerifiers(jwksJSON: jwksJSON(keys: [rsaJWK()]))
        #expect(throws: (any Error).self) {
            try verifiers.verify(token, header: JWTHeader(alg: "RS256", typ: "JWT", kid: "rotated-away"))
        }
    }

    // MARK: - JWKS robustness

    @Test("Unsupported keys in the JWKS are skipped without breaking the set")
    func testExoticKeysSkipped() throws {
        let signingKey = try RSAKey.private(pem: Self.rsaPrivatePEM)
        let signer = JWTSigners()
        signer.use(.rs256(key: signingKey), kid: "rsa-key")
        let token = try signer.sign(makeClaims(), kid: "rsa-key")

        let jwks = try jwksJSON(keys: [
            // Key type JWTKit doesn't model.
            ["kty": "EC", "alg": "ES256K", "kid": "secp-key", "crv": "secp256k1", "x": "AA", "y": "AA"],
            // Symmetric key — must never become a verifier.
            ["kty": "oct", "alg": "HS256", "kid": "oct-key", "k": "c2VjcmV0"],
            // Encryption key, not for signatures.
            rsaJWK(kid: "enc-key", use: "enc"),
            rsaJWK(),
        ])
        let verifiers = try OIDCTokenVerification.makeVerifiers(jwksJSON: jwks)
        let claims = try verifiers.verify(token, header: JWTHeader(alg: "RS256", typ: "JWT", kid: "rsa-key"))
        #expect(claims.sub == "user-123")
    }

    @Test("A kid-less single-key JWKS verifies a kid-less token")
    func testKidlessKeyAndToken() throws {
        let signingKey = try RSAKey.private(pem: Self.rsaPrivatePEM)
        let signer = JWTSigners()
        signer.use(.rs256(key: signingKey))
        let token = try signer.sign(makeClaims())

        var jwk = rsaJWK()
        jwk.removeValue(forKey: "kid")
        let verifiers = try OIDCTokenVerification.makeVerifiers(jwksJSON: jwksJSON(keys: [jwk]))
        let claims = try verifiers.verify(token, header: JWTHeader(alg: "RS256", typ: "JWT", kid: nil))
        #expect(claims.sub == "user-123")
    }

    @Test("JWKS with no usable signing keys is an error")
    func testNoUsableKeys() throws {
        let encOnly = try jwksJSON(keys: [rsaJWK(kid: "enc-key", use: "enc")])
        #expect(throws: (any Error).self) {
            try OIDCTokenVerification.makeVerifiers(jwksJSON: encOnly)
        }
        let empty = try jwksJSON(keys: [])
        #expect(throws: (any Error).self) {
            try OIDCTokenVerification.makeVerifiers(jwksJSON: empty)
        }
        #expect(throws: (any Error).self) {
            try OIDCTokenVerification.makeVerifiers(jwksJSON: Data("not json".utf8))
        }
    }
}
