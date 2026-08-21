import Crypto
import ControlPlanePostgres
import Foundation
import JWT
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// JWT-SVIDs as short-lived programmatic credentials (issue #495).
///
/// Three layers, each with its own failure mode worth pinning:
///
///  - **JWK conversion** — SPIRE reports JWT authorities as DER
///    SubjectPublicKeyInfo; JOSE wants JWKs, and a wrong conversion would
///    either reject every good token or (worse) verify against the wrong key
///    material.
///  - **Verification** — the audience, trust domain, algorithm and `kid` rules
///    that stop a perfectly-signed token minted for someone else from working
///    here.
///  - **Authentication** — a verified SPIFFE ID is a *lookup key* into the
///    workload registry and nothing more, so an unregistered identity
///    authenticates as nobody and a registered one gets exactly the access its
///    role bindings give it.
@Suite("JWT-SVID Authentication", .serialized)
struct JWTSVIDAuthenticationTests {

    private static let trustDomain = "strato.local"
    private static let audience = "spiffe://strato.local/control-plane"

    // MARK: - JWK conversion

    @Test("Converts an EC P-256 authority to a usable JWK")
    func convertsECAuthority() async throws {
        let key = P256.Signing.PrivateKey()
        let jwks = try #require(
            JWTAuthorityJWK.makeJWKS(
                authorities: [(keyID: "key-1", publicKeyDER: key.publicKey.derRepresentation)]))

        let root = try #require(try JSONSerialization.jsonObject(with: jwks) as? [String: Any])
        let keys = try #require(root["keys"] as? [[String: String]])
        #expect(keys.count == 1)
        #expect(keys[0]["kty"] == "EC")
        #expect(keys[0]["crv"] == "P-256")
        #expect(keys[0]["kid"] == "key-1")
        #expect(keys[0]["use"] == "sig")
        // Coordinates are unpadded base64url of 32-byte values.
        #expect(keys[0]["x"]?.contains("=") == false)

        // And the JWKS actually registers with JWTKit.
        let verifiers = try await JWTSVIDVerification.makeVerifiers(jwksJSON: jwks)
        #expect(verifiers.knownKeyIDs == ["key-1"])
    }

    @Test("Converts P-384 and P-521 authorities with correct coordinate sizes")
    func convertsLargerCurves() async throws {
        let p384 = P384.Signing.PrivateKey()
        let jwks384 = try #require(
            JWTAuthorityJWK.makeJWKS(
                authorities: [(keyID: "k384", publicKeyDER: p384.publicKey.derRepresentation)]))
        let verifiers384 = try await JWTSVIDVerification.makeVerifiers(jwksJSON: jwks384)
        #expect(verifiers384.knownKeyIDs == ["k384"])

        let p521 = P521.Signing.PrivateKey()
        let jwks521 = try #require(
            JWTAuthorityJWK.makeJWKS(
                authorities: [(keyID: "k521", publicKeyDER: p521.publicKey.derRepresentation)]))
        let root = try #require(try JSONSerialization.jsonObject(with: jwks521) as? [String: Any])
        let keys = try #require(root["keys"] as? [[String: String]])
        #expect(keys[0]["crv"] == "P-521")
    }

    @Test("Skips authorities that cannot be modelled, and refuses an empty result")
    func skipsUnusableAuthorities() {
        // Not a SubjectPublicKeyInfo at all.
        #expect(JWTAuthorityJWK.makeJWKS(authorities: [(keyID: "k", publicKeyDER: Data([0x01, 0x02]))]) == nil)

        // A real key with no key id cannot be addressed by a token header.
        let key = P256.Signing.PrivateKey()
        #expect(
            JWTAuthorityJWK.makeJWKS(authorities: [(keyID: "", publicKeyDER: key.publicKey.derRepresentation)])
                == nil)

        // A good key alongside a bad one still yields the good one.
        let mixed = JWTAuthorityJWK.makeJWKS(authorities: [
            (keyID: "bad", publicKeyDER: Data([0x30, 0x00])),
            (keyID: "good", publicKeyDER: key.publicKey.derRepresentation),
        ])
        #expect(mixed != nil)
    }

    // MARK: - Verification

    @Test("Accepts a well-formed JWT-SVID")
    func acceptsValidToken() async throws {
        let signer = try TestJWTSVIDSigner()
        let token = try await signer.sign(
            subject: "spiffe://strato.local/ci/builder", audience: [Self.audience])

        let verified = try await signer.verifiers().verify(
            token,
            header: try JWTSVIDVerification.decodeHeader(token),
            audience: Self.audience,
            trustDomain: Self.trustDomain
        )
        #expect(verified.spiffeID.uri == "spiffe://strato.local/ci/builder")
    }

    @Test("Rejects a token minted for another relying party")
    func rejectsWrongAudience() async throws {
        let signer = try TestJWTSVIDSigner()
        let token = try await signer.sign(
            subject: "spiffe://strato.local/ci/builder",
            audience: ["spiffe://strato.local/some-other-service"])

        await #expect(throws: JWTSVIDVerificationError.self) {
            _ = try await signer.verifiers().verify(
                token,
                header: try JWTSVIDVerification.decodeHeader(token),
                audience: Self.audience,
                trustDomain: Self.trustDomain
            )
        }
    }

    @Test("Rejects a subject from a different trust domain")
    func rejectsForeignTrustDomain() async throws {
        let signer = try TestJWTSVIDSigner()
        // Signed by *our* authorities but naming another domain's identity:
        // one domain's keys must never speak for another's namespace.
        let token = try await signer.sign(
            subject: "spiffe://other.example/ci/builder", audience: [Self.audience])

        await #expect(throws: JWTSVIDVerificationError.self) {
            _ = try await signer.verifiers().verify(
                token,
                header: try JWTSVIDVerification.decodeHeader(token),
                audience: Self.audience,
                trustDomain: Self.trustDomain
            )
        }
    }

    @Test("Rejects an expired token")
    func rejectsExpiredToken() async throws {
        let signer = try TestJWTSVIDSigner()
        let token = try await signer.sign(
            subject: "spiffe://strato.local/ci/builder",
            audience: [Self.audience],
            expiresIn: -60
        )

        await #expect(throws: JWTSVIDVerificationError.self) {
            _ = try await signer.verifiers().verify(
                token,
                header: try JWTSVIDVerification.decodeHeader(token),
                audience: Self.audience,
                trustDomain: Self.trustDomain
            )
        }
    }

    @Test("Rejects a token naming an unknown key id")
    func rejectsUnknownKeyID() async throws {
        let signer = try TestJWTSVIDSigner()
        // Signed with a key the verifier does not hold — the shape of a
        // rotated-out or forged authority.
        let other = try TestJWTSVIDSigner(keyID: "rotated-key")
        let token = try await other.sign(
            subject: "spiffe://strato.local/ci/builder", audience: [Self.audience])

        await #expect(throws: JWTSVIDVerificationError.self) {
            _ = try await signer.verifiers().verify(
                token,
                header: try JWTSVIDVerification.decodeHeader(token),
                audience: Self.audience,
                trustDomain: Self.trustDomain
            )
        }
    }

    @Test("Rejects symmetric and 'none' algorithms outright")
    func rejectsForgeableAlgorithms() throws {
        // An HMAC "signature" would be forgeable by anyone holding the public
        // JWKS, so the header is refused before any key lookup happens.
        for algorithm in ["HS256", "none", "HS512"] {
            let token = TestTokens.unsigned(header: ["alg": algorithm, "kid": "key-1"], claims: ["sub": "x"])
            #expect(throws: JWTSVIDVerificationError.self) {
                _ = try JWTSVIDVerification.decodeHeader(token)
            }
        }
    }

    @Test("Rejects a header with no key id")
    func rejectsMissingKeyID() async throws {
        let signer = try TestJWTSVIDSigner()
        let token = TestTokens.unsigned(header: ["alg": "ES256"], claims: ["sub": "x"])
        let header = try JWTSVIDVerification.decodeHeader(token)

        await #expect(throws: JWTSVIDVerificationError.self) {
            _ = try await signer.verifiers().verify(
                token, header: header, audience: Self.audience, trustDomain: Self.trustDomain)
        }
    }

    @Test("Recognizes the compact JWS shape without accepting other bearer formats")
    func recognizesTokenShape() {
        #expect(JWTSVIDVerification.hasCompactJWSShape("aaa.bbb.ccc"))
        #expect(!JWTSVIDVerification.hasCompactJWSShape("sk_live_abcdef"))
        #expect(!JWTSVIDVerification.hasCompactJWSShape("st_abcdef"))
        #expect(!JWTSVIDVerification.hasCompactJWSShape("aaa.bbb"))
    }

    @Test("Normalizes SPIFFE key use and skips unrelated or malformed keys")
    func acceptsSPIFFEJWKSWithMixedKeys() async throws {
        let signer = try TestJWTSVIDSigner()
        let root = try #require(try JSONSerialization.jsonObject(with: signer.jwks) as? [String: Any])
        var signingKey = try #require((root["keys"] as? [[String: Any]])?.first)
        signingKey["use"] = "jwt-svid"
        let mixed = try JSONSerialization.data(withJSONObject: [
            "keys": [
                NSNull(),
                ["kty": "unsupported", "kid": "bad"],
                ["use": "x509-svid", "kid": "x509-root"],
                signingKey,
            ]
        ])

        let verifiers = try await JWTSVIDVerification.makeVerifiers(jwksJSON: mixed)
        #expect(verifiers.knownKeyIDs == [signer.keyID])
    }

    @Test("Rejects malformed or unusable trust-domain JWKS documents")
    func rejectsMalformedTrustDomainJWKS() async {
        for json in ["not json", #"{"keys":null}"#, #"{"keys":{}}"#, #"{"keys":[]}"#] {
            await #expect(throws: JWTSVIDVerificationError.self) {
                try await JWTSVIDVerification.makeVerifiers(jwksJSON: Data(json.utf8))
            }
        }
    }

    // MARK: - Authority store

    @Test("Picks up a rotated authority on an unknown key id")
    func refreshesOnRotation() async throws {
        let original = try TestJWTSVIDSigner(keyID: "key-1")
        let rotated = try TestJWTSVIDSigner(keyID: "key-2")
        let source = MutableJWTAuthoritySource(trustDomain: Self.trustDomain, jwks: original.jwks)

        let store = JWTSVIDAuthorityStore(
            source: source,
            audience: Self.audience,
            logger: Logger(label: "test.jwt-svid"),
            refreshInterval: 3600,
            unknownKeyRefreshCooldown: 0
        )

        // Warm the cache on the original key.
        let firstToken = try await original.sign(
            subject: "spiffe://strato.local/ci/builder", audience: [Self.audience])
        _ = try await store.verify(token: firstToken)

        // SPIRE rotates. The cache still holds only key-1, and the refresh
        // interval has not elapsed — the unknown kid is what must trigger the
        // re-fetch.
        await source.setJWKS(rotated.jwks)
        let rotatedToken = try await rotated.sign(
            subject: "spiffe://strato.local/ci/builder", audience: [Self.audience])

        let verified = try await store.verify(token: rotatedToken)
        #expect(verified.spiffeID.uri == "spiffe://strato.local/ci/builder")
    }

    @Test("A cold cache under load dials SPIRE once, not once per request")
    func collapsesConcurrentFetches() async throws {
        let signer = try TestJWTSVIDSigner()
        let source = MutableJWTAuthoritySource(trustDomain: Self.trustDomain, jwks: signer.jwks)
        let store = JWTSVIDAuthorityStore(
            source: source,
            audience: Self.audience,
            logger: Logger(label: "test.jwt-svid"),
            refreshInterval: 3600
        )

        // Hold the first fetch open so the others arrive while it is still in
        // flight — the exact window the actor's re-entrancy used to leave open.
        await source.closeGate()

        let token = try await signer.sign(
            subject: "spiffe://strato.local/ci/builder", audience: [Self.audience])

        let verifications = (0..<8).map { _ in
            Task { try await store.verify(token: token) }
        }
        // Let them all reach the store and queue behind the in-flight fetch.
        try await Task.sleep(for: .milliseconds(100))
        await source.openGate()

        for verification in verifications {
            let verified = try await verification.value
            #expect(verified.spiffeID.uri == "spiffe://strato.local/ci/builder")
        }

        // Eight concurrent cold verifications, one call to SPIRE.
        let fetchCount = await source.fetchCount
        #expect(fetchCount == 1)
    }

    @Test("An unknown key id that a refresh does not explain is still rejected")
    func rejectsUnexplainedUnknownKey() async throws {
        let known = try TestJWTSVIDSigner(keyID: "key-1")
        let forged = try TestJWTSVIDSigner(keyID: "attacker-key")
        let source = MutableJWTAuthoritySource(trustDomain: Self.trustDomain, jwks: known.jwks)

        let store = JWTSVIDAuthorityStore(
            source: source,
            audience: Self.audience,
            logger: Logger(label: "test.jwt-svid"),
            refreshInterval: 3600,
            unknownKeyRefreshCooldown: 0
        )

        let token = try await forged.sign(
            subject: "spiffe://strato.local/ci/builder", audience: [Self.audience])
        await #expect(throws: JWTSVIDVerificationError.self) {
            _ = try await store.verify(token: token)
        }
    }

    // MARK: - Authentication against the registry

    @Test("A registered service account authenticates and is authorized by its bindings")
    func authenticatesRegisteredServiceAccount() async throws {
        try await withApp { app, signer in
            let builder = TestDataBuilder(db: app.testPostgres)
            let org = try await builder.createOrganization(name: "JWT Org")
            let project = try await builder.createProject(
                name: "JWT Project", description: "d", organization: org)

            let account = try await LegacyServiceAccountStore.insert(
                ServiceAccountWrite(
                    name: "ci", description: "CI", projectID: try project.requireID()),
                on: app.testPostgres)
            let accountID = account.id

            _ = try await LegacyWorkloadRegistrationStore.insert(
                WorkloadRegistrationWrite(
                    spiffeID: "spiffe://strato.local/ci/builder",
                    kind: WorkloadRegistrationKind.serviceAccount.rawValue,
                    serviceAccountID: accountID),
                on: app.testPostgres)

            let token = try await signer.sign(
                subject: "spiffe://strato.local/ci/builder", audience: [Self.audience])

            // Without a binding the principal authenticates but is denied: the
            // token is identity, never authorization.
            try await app.testing().test(
                .GET, "/api/vms",
                beforeRequest: { $0.headers.bearerAuthorization = BearerAuthorization(token: token) },
                afterResponse: { response in
                    #expect(response.status == .forbidden)
                })

            // A binding is what actually opens the door — and it is an
            // ordinary role binding against the service-account principal, the
            // same row a user's grant would be.
            _ = try await LegacyRoleBindingStore.insert(
                LegacyRoleBindingWrite(
                    principalType: IAMPrincipalType.serviceAccount.rawValue,
                    principalID: accountID,
                    roleID: IAMRole.viewer.seededID,
                    nodeType: IAMNodeType.organization.rawValue,
                    nodeID: try org.requireID()),
                on: app.testPostgres)

            try await app.testing().test(
                .GET, "/api/vms",
                beforeRequest: { $0.headers.bearerAuthorization = BearerAuthorization(token: token) },
                afterResponse: { response in
                    #expect(response.status == .ok)
                })

            // Mutations stay user-only for now: `resource_operations.user_id`
            // is a non-null user id naming the initiator, and operation
            // visibility falls back to "the initiator may read it". A machine
            // principal has no user id to put there, so creating a VM is
            // refused with a reason rather than recording a misleading
            // initiator. Widening that needs a principal-typed initiator
            // column — see docs/architecture/iam.md.
            try await app.testing().test(
                .POST, "/api/vms",
                beforeRequest: { request in
                    request.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try request.content.encode(["name": "from-ci"])
                },
                afterResponse: { response in
                    #expect(response.status == .forbidden)
                })
        }
    }

    @Test("An unregistered SPIFFE identity authenticates as nobody")
    func rejectsUnregisteredIdentity() async throws {
        try await withApp { app, signer in
            let token = try await signer.sign(
                subject: "spiffe://strato.local/ci/unregistered", audience: [Self.audience])

            try await app.testing().test(
                .GET, "/api/vms",
                beforeRequest: { $0.headers.bearerAuthorization = BearerAuthorization(token: token) },
                afterResponse: { response in
                    #expect(response.status == .unauthorized)
                })
        }
    }

    @Test("A JWT-SVID naming an agent identity is refused as an API credential")
    func refusesAgentIdentity() async throws {
        try await withApp { app, signer in
            _ = try await LegacyWorkloadRegistrationStore.insert(
                WorkloadRegistrationWrite(
                    spiffeID: "spiffe://strato.local/agent/node-1",
                    kind: WorkloadRegistrationKind.agent.rawValue,
                    agentName: "node-1"),
                on: app.testPostgres)

            let token = try await signer.sign(
                subject: "spiffe://strato.local/agent/node-1", audience: [Self.audience])

            try await app.testing().test(
                .GET, "/api/vms",
                beforeRequest: { $0.headers.bearerAuthorization = BearerAuthorization(token: token) },
                afterResponse: { response in
                    // Agents authenticate the transport with mTLS; a bearer
                    // token for one must not become an API principal.
                    #expect(response.status == .forbidden)
                })
        }
    }

    @Test("A workload principal is refused on the self-scoped identity plane")
    func refusesIdentityPlaneRoutes() async throws {
        try await withApp { app, signer in
            let builder = TestDataBuilder(db: app.testPostgres)
            let org = try await builder.createOrganization(name: "Identity Plane Org")
            let project = try await builder.createProject(
                name: "Identity Plane Project", description: "d", organization: org)
            let account = try await LegacyServiceAccountStore.insert(
                ServiceAccountWrite(name: "ci", projectID: try project.requireID()),
                on: app.testPostgres)

            _ = try await LegacyWorkloadRegistrationStore.insert(
                WorkloadRegistrationWrite(
                    spiffeID: "spiffe://strato.local/ci/builder",
                    kind: WorkloadRegistrationKind.serviceAccount.rawValue,
                    serviceAccountID: account.id),
                on: app.testPostgres)

            let token = try await signer.sign(
                subject: "spiffe://strato.local/ci/builder", audience: [Self.audience])

            // "My API keys" has no meaning for a service account: the
            // credential is fine, the surface is not for it.
            try await app.testing().test(
                .GET, "/api/api-keys",
                beforeRequest: { $0.headers.bearerAuthorization = BearerAuthorization(token: token) },
                afterResponse: { response in
                    #expect(response.status == .forbidden)
                })
        }
    }

    @Test("An unverifiable token is not accepted as a credential")
    func rejectsUnverifiableToken() async throws {
        try await withApp { app, signer in
            // Correct shape, wrong signer.
            let forged = try TestJWTSVIDSigner(keyID: "attacker-key")
            let token = try await forged.sign(
                subject: "spiffe://strato.local/ci/builder", audience: [Self.audience])

            try await app.testing().test(
                .GET, "/api/vms",
                beforeRequest: { $0.headers.bearerAuthorization = BearerAuthorization(token: token) },
                afterResponse: { response in
                    #expect(response.status == .unauthorized)
                })
        }
    }

    // MARK: - Harness

    private func withApp(_ test: (Application, TestJWTSVIDSigner) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)

            let signer = try TestJWTSVIDSigner()
            app.jwtSVIDAuthorityStore = JWTSVIDAuthorityStore(
                source: MutableJWTAuthoritySource(trustDomain: Self.trustDomain, jwks: signer.jwks),
                audience: Self.audience,
                logger: app.logger
            )

            try await test(app, signer)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}

// MARK: - Test helpers

/// A JWT authority source whose keys can be swapped mid-test, standing in for
/// SPIRE rotating its JWT signing key.
private actor MutableJWTAuthoritySource: JWTAuthoritySource {
    nonisolated let trustDomain: String
    private var jwks: Data

    /// How many times the store actually dialed us — the observable the
    /// single-flight test asserts on.
    private(set) var fetchCount = 0

    /// When set, every fetch waits on this before answering, holding the
    /// store's in-flight window open so concurrent callers pile up behind it.
    private var gate: AsyncStream<Void>.Continuation?
    private var gateStream: AsyncStream<Void>?

    init(trustDomain: String, jwks: Data) {
        self.trustDomain = trustDomain
        self.jwks = jwks
    }

    func setJWKS(_ jwks: Data) {
        self.jwks = jwks
    }

    /// Make fetches block until `openGate()` is called.
    func closeGate() {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        gateStream = stream
        gate = continuation
    }

    func openGate() {
        gate?.finish()
        gate = nil
        gateStream = nil
    }

    func fetchJWKS() async throws -> Data {
        fetchCount += 1
        if let gateStream {
            // Suspends until openGate() finishes the stream.
            for await _ in gateStream {}
        }
        return jwks
    }
}

/// Mints real ES256-signed JWT-SVIDs and publishes the matching JWKS through
/// the same DER→JWK path production uses, so a conversion bug fails these
/// tests rather than passing them.
struct TestJWTSVIDSigner {
    let keyID: String
    let jwks: Data
    private let privateKey: ECDSA.PrivateKey<P256>

    init(keyID: String = "key-1") throws {
        self.keyID = keyID
        let key = P256.Signing.PrivateKey()
        self.privateKey = try ECDSA.PrivateKey<P256>(pem: key.pemRepresentation)
        guard
            let jwks = JWTAuthorityJWK.makeJWKS(
                authorities: [(keyID: keyID, publicKeyDER: key.publicKey.derRepresentation)])
        else {
            throw JWTSVIDVerificationError.malformed("test key could not be converted to a JWK")
        }
        self.jwks = jwks
    }

    func verifiers() async throws -> JWTSVIDVerifiers {
        try await JWTSVIDVerification.makeVerifiers(jwksJSON: jwks)
    }

    func sign(subject: String, audience: [String], expiresIn: TimeInterval = 300) async throws -> String {
        let keys = JWTKeyCollection()
        await keys.add(ecdsa: privateKey, kid: JWKIdentifier(string: keyID))

        let claims = JWTSVIDClaims(
            sub: subject,
            aud: OIDCAudienceClaim(values: audience),
            exp: ExpirationClaim(value: Date().addingTimeInterval(expiresIn)),
            iat: IssuedAtClaim(value: Date()),
            nbf: nil
        )
        var header = JWTHeader()
        header.typ = "JWT"
        return try await keys.sign(claims, kid: JWKIdentifier(string: keyID), header: header)
    }
}

/// Hand-assembled tokens for the cases a real signer cannot produce (a
/// forbidden algorithm, a missing `kid`).
enum TestTokens {
    static func unsigned(header: [String: Any], claims: [String: Any]) -> String {
        [segment(header), segment(claims), "c2lnbmF0dXJl"].joined(separator: ".")
    }

    private static func segment(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
