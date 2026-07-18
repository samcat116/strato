import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Vapor
import VaporTesting

import JWT

@testable import App

// MARK: - Test RSA Keypair Fixtures

/// Throwaway 2048-bit RSA keypairs generated for these tests only (never used
/// outside the suite). The JWK `n`/`e` values are the base64url encoding of
/// each key's modulus and public exponent, matching what a real IdP publishes
/// in its JWKS document.
private enum TestRSAKeys {
    static let privateKeyPEM = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEogIBAAKCAQEA1R53U3UOjZcCNXx8P0DG5t68keJJBR3lNrwFIg5PbzXh+2ZM
        xGBBmS9eGxKKppMYNug92jhL1OTkHRweukj3ICp4Qkj7HI/gieE4eQgJhQJzbEjT
        sZrn7aNu1oqXU0kvZIZLEZmtT15Z8VCcs+xI66TzUFiDaStBMf6milYm9/pNl2v/
        3ZC+8Hw8gfW2XuQLhfUPw0bYO3ssgtPjpjDv3uvX0wgIRiRyyju9j/ueTG9oN/py
        lrVAmJYcFriICFoAiD7knaF5xHx8HWk6IB51oq/6idfsEQflFvrZjX5yoD3MGcQM
        wZRSjGa5wy8PhsXf3eToxqxmB0EWZoFfLEEcgQIDAQABAoIBAClo2AqxTfiZBObb
        n1CzB3LIiJ9X9pQ18Nmnwt+RJEIZmCU/BV+KzHQ1TfW4rpQbNLNGgO4rziA5sVEu
        q5HKp6nqVp+aiqBMHHbt+gkaVK8xgLfjlq6FyNbV0K2DFFAsgjboGSH8WD55uMQ4
        w5n6KVkQHe7YpAAFVY+fSUDL6Jp5/z8RKBAm2aMHUSSVrLzZnmMfV0fvA/87ToN1
        cNtuMF7RHIEkH8aFAlEq0TqFDVWggPkFzN53TgEMw0543dzfMlOdYykL5nMJkWqR
        Xl+Zwj9h7qKE5+836cLkkkyCEk2iMHxczy0uWPvFhnBl0U6I7I8ylEoH1YI1jp6l
        OS+VbIECgYEA9mZhE3LBjApLrJ+2pVI+PYKXGS3N/a8znG+mPE1k0r18UC8w/our
        3G1eN4cqZHNMITZkqika9gFuT7VrJcOXxwtWpSRZPcchIgcM2QpyIIx1/DKxPnBJ
        H9mlN52bZ8zOKpCpyDqtjoOILJOiEQ9spkhzCHDFPP+C7w08FsYc8kkCgYEA3Wwj
        qyJq91rFkSHWgECWnygfO1ARe2mYOUrJNZ+APyAzHKSr9SEaxFDw741BKoP7YTDQ
        KodU9ulxxc0szye/d2QQmbr/86NKxwGZHRMY5Sq6iTUaztYvDMCQgyghJXL4Awb3
        N1bSsvGzH5UHZBpsvmLXVGbeNAvSj/bOWlr92HkCgYA+fmz0r9BjImFbIQ8EEz3x
        /+Mu4a0zQHKIpNC2zrJZuPGErNNyXB50w9B3qPKZk5yld9RETDSoXGiMEulgJKGk
        PD33mKaBwrWmmb8qdTnJA5cRJhJKUdRaHauH1ZOK2ikYJqTJQgiu8rFhDPi39v+J
        lSqH44JDHFMrKmIpLIo+8QKBgG0EUC9zG607oOhK+7xbkI0+CNqAGotjuxICMzzW
        kiMCbIfev9dJ/E7J90ZKitou7zaz/Nnjlb6Xw297DGPWExvqRY4bFufS7v86VzOM
        coZqWjsxzUgnBjVGHiClQmSYzWlYJaG2eril7eZPzrrHk+DM823X0/FWHM7K2mB8
        Sl0pAoGAX2uzhMG1eccuUMIc4ZXTBpFfbC0rzCWHPDswxtLKRDce67tm87eHQQgn
        Um+1QDDqEobm1dvnP028tPodXiR7ibGQ51GA7dpoyhrkTa1AOUDVCF6mdJflp8GV
        YZuJ0WWlr61NFeAfNt1cKLv2IMsIUdTc1Etkbrp9NXZF+qf1w5U=
        -----END RSA PRIVATE KEY-----
        """

    static let modulus =
        "1R53U3UOjZcCNXx8P0DG5t68keJJBR3lNrwFIg5PbzXh-2ZMxGBBmS9eGxKKppMYNug92jhL1OTkHRweukj3ICp4Qkj7HI_gieE4eQgJ"
        + "hQJzbEjTsZrn7aNu1oqXU0kvZIZLEZmtT15Z8VCcs-xI66TzUFiDaStBMf6milYm9_pNl2v_3ZC-8Hw8gfW2XuQLhfUPw0bYO3ssgtPj"
        + "pjDv3uvX0wgIRiRyyju9j_ueTG9oN_pylrVAmJYcFriICFoAiD7knaF5xHx8HWk6IB51oq_6idfsEQflFvrZjX5yoD3MGcQMwZRSjGa5"
        + "wy8PhsXf3eToxqxmB0EWZoFfLEEcgQ"

    /// A second, unrelated keypair used to produce signatures the first key
    /// must reject.
    static let otherPrivateKeyPEM = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEpAIBAAKCAQEA/tWjx2+qVjljq4grtnoTt8GJzs2V5Iq1Mm8yDqmVQMJu5wZm
        V31vBrovcGMoHhiq4xZHI7aTU74Lzg5QADoHMR/be+LgCCfUQSKaBBXC+aOETEkF
        A2qFjRajgM28bXpRBH4eTu0UZ16HbvRagr7/QGBM5MTIms1qIRmK090xsjP/38gv
        YvVjJx4hulq9hWfj4dgAC0WYIeD+8il6JWad5PO3GKpZ/L+x/W9CqG07OMDnKn0y
        YFEzWsbnKul9LEZljbC4r+FAgsbb5qOc7cGQTAt3jvLu+1TSUXHzF71FA7ncew+k
        a/eH8Jh5iqpTnMaMZ0/yX5hm7CHPjKqfzdkbiwIDAQABAoIBABxNwD4TcfjXsPFJ
        U4mV74C2V0cH4IEcwtlSLl4gibpCniy8sjs/bEhz/3bdHISTOs+0Frypt51Se18s
        icgsqcXUAv20iit9uP5vCGoxvJEbj0MlzQ+/EgxEmm5g62/BaSQ1mcosXNrKTgKN
        00u4SQNubrvt+1XuQL5iZt/3LmDbWvA2jRbqOE8UbQMSa9JWNxhOylkm1O84Q5ou
        bTn9QGyn4II5AV1Z2naZYtPhKzGrKp+KXEhS2uEdh/PDjZCZkVQB0s4aApeebyuO
        uUsgaaK6YKdEO0FNU46S4mDAZWmi/X4kyIlg9T9yJui9edrM/cbXyMVJhjO4OJol
        kVDPgPECgYEA/+6zoRcw8yi9q7mcmaOB4njPc8TDQobBStMmmpu0ysC9TEoZbn5V
        LR6hvI/rHihfPQgIi8tqOF5Or/57D1e5LEHE5JxweqKfBGnGm6wU8YzO7FO3gF4k
        LOZJ8scFMU3U8cjRy1Pi5kVPPZ0xpQB6JqWnwyvyoFJPX8BNz+e+mEkCgYEA/ubd
        JymATlNkJomAmNR/XYBR2oesE+g+crmdtfzkxWS0AJdL5Xee5KgViUlt7G4Ykl7F
        sBasanCe3VcBCjByAUlHNLCMx12j239UMzzmzJFx9AOrCtGkiQFHsNg8WCZIRDvH
        y3FJ5Dsmr1u2+1dNC59YyO0EOWvXI1yWXlucnTMCgYBTPgxm5Ogi7qliZWiuACSK
        yMiQ2vq3dKUB9VOlDefr2my3l5JWAfkqR8BLWHQcxvzTGP3OmkbeNq5ZR+g2wU2V
        O38S7F8ZRDN8d/sFPx9AwY+8Bi61LemOQQjkUh86Php42dyCybIPO5PecnZnOJSC
        ZXb/YBf2VU9D0YR9jt7LIQKBgQDcTighqsrL52MNs5XDgRU7eKZGGzBsXDNs8GQQ
        YCxRNoIkaJ8eCk74DRXf++jXiSgPiX2OfWoy7HdBkerCJbDCz9SNA3II9TOjh978
        EczgTWyRm4H+7cYo60RM4fb1sNCQuKIrgRR9/2ml8byqan+aZfRUZBVck4nzdBg6
        IS+w5QKBgQD70pG00SnYYJy9KiU/Gvxsum0rMDfTXig3pHrjDTrOKcGF7ahnDw4M
        Uvy3gLh1/9OhOChfJCwsUJ34h+STRhHfvljzEAuIgg9XczyKNUUwm0Eutt0O+TLM
        JpsCQTDGiqmLpaG2pKK+jMzHF0cXdTGCcv4gycOXA5EWaKrx22X/Jw==
        -----END RSA PRIVATE KEY-----
        """

    static let exponent = "AQAB"
    static let keyID = "test-key"
}

// MARK: - Signed Token Helpers

/// Mirrors `OIDCIDTokenClaims` but with every field writable, so tests can
/// mint tokens with any combination of good and bad claims.
private struct TestIDTokenClaims: JWTPayload {
    var iss: String
    var sub: String
    var aud: String
    var exp: ExpirationClaim
    var iat: IssuedAtClaim
    var azp: String?
    var nonce: String?
    var email: String?
    var emailVerified: Bool?
    var name: String?

    func verify(using algorithm: some JWTAlgorithm) async throws {}

    private enum CodingKeys: String, CodingKey {
        case iss, sub, aud, exp, iat, azp, nonce, email, name
        case emailVerified = "email_verified"
    }
}

private func signIDToken(
    iss: String = "https://idp.example.com",
    sub: String = "sub-123",
    aud: String = "client-abc",
    azp: String? = nil,
    expiresIn: TimeInterval = 300,
    nonce: String?,
    email: String? = "sso-user@example.com",
    emailVerified: Bool? = true,
    kid: String = TestRSAKeys.keyID,
    privateKeyPEM: String = TestRSAKeys.privateKeyPEM
) async throws -> String {
    let claims = TestIDTokenClaims(
        iss: iss,
        sub: sub,
        aud: aud,
        exp: ExpirationClaim(value: Date().addingTimeInterval(expiresIn)),
        iat: IssuedAtClaim(value: Date()),
        azp: azp,
        nonce: nonce,
        email: email,
        emailVerified: emailVerified,
        name: "SSO User"
    )
    let keys = JWTKeyCollection()
    let key = try Insecure.RSA.PrivateKey(pem: privateKeyPEM)
    await keys.add(rsa: key, digestAlgorithm: .sha256, kid: JWKIdentifier(string: kid))
    return try await keys.sign(claims, kid: JWKIdentifier(string: kid))
}

/// Same as `TestIDTokenClaims` but with a multi-valued `aud`, mirroring
/// providers (e.g. Discord) that encode the audience as a JSON array. A plain
/// `[String]` always encodes as an array, even for a single element.
private struct TestIDTokenArrayAudClaims: JWTPayload {
    var iss: String
    var sub: String
    var aud: [String]
    var exp: ExpirationClaim
    var iat: IssuedAtClaim
    var azp: String?
    var nonce: String?
    var email: String?
    var emailVerified: Bool?
    var name: String?

    func verify(using algorithm: some JWTAlgorithm) async throws {}

    private enum CodingKeys: String, CodingKey {
        case iss, sub, aud, exp, iat, azp, nonce, email, name
        case emailVerified = "email_verified"
    }
}

private func signIDTokenArrayAud(
    aud: [String],
    azp: String? = nil,
    iss: String = "https://idp.example.com",
    sub: String = "sub-123",
    expiresIn: TimeInterval = 300,
    nonce: String?,
    email: String? = "sso-user@example.com",
    kid: String = TestRSAKeys.keyID,
    privateKeyPEM: String = TestRSAKeys.privateKeyPEM
) async throws -> String {
    let claims = TestIDTokenArrayAudClaims(
        iss: iss,
        sub: sub,
        aud: aud,
        exp: ExpirationClaim(value: Date().addingTimeInterval(expiresIn)),
        iat: IssuedAtClaim(value: Date()),
        azp: azp,
        nonce: nonce,
        email: email,
        emailVerified: true,
        name: "SSO User"
    )
    let keys = JWTKeyCollection()
    let key = try Insecure.RSA.PrivateKey(pem: privateKeyPEM)
    await keys.add(rsa: key, digestAlgorithm: .sha256, kid: JWKIdentifier(string: kid))
    return try await keys.sign(claims, kid: JWKIdentifier(string: kid))
}

private func jwksJSON(kid: String = TestRSAKeys.keyID, modulus: String = TestRSAKeys.modulus) -> String {
    """
    {"keys":[{"kty":"RSA","use":"sig","kid":"\(kid)","n":"\(modulus)","e":"\(TestRSAKeys.exponent)","alg":"RS256"}]}
    """
}

private func tokenResponseJSON(idToken: String) -> String {
    """
    {"access_token":"at-1","token_type":"Bearer","expires_in":3600,"id_token":"\(idToken)"}
    """
}

// MARK: - Scriptable HTTP Client

/// Fake Vapor `Client` standing in for the IdP: responses are scripted per URL
/// substring, and every outgoing request is recorded so tests can assert on
/// the exact shape of the token-exchange POST.
private final class FakeIdPClient: Client, @unchecked Sendable {
    struct Stub {
        var status: HTTPStatus
        var body: String
    }

    let eventLoop: EventLoop
    private let lock = NIOLock()
    private var stubs: [(match: String, stub: Stub)] = []
    private var recorded: [ClientRequest] = []

    init(on eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    func stub(urlContaining match: String, status: HTTPStatus = .ok, json: String) {
        lock.withLock { stubs.append((match, Stub(status: status, body: json))) }
    }

    var requests: [ClientRequest] {
        lock.withLock { recorded }
    }

    func requests(urlContaining match: String) -> [ClientRequest] {
        lock.withLock { recorded.filter { $0.url.string.contains(match) } }
    }

    func delegating(to eventLoop: EventLoop) -> Client {
        self
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        // Last matching stub wins, so a test can re-stub an endpoint for a
        // second login attempt.
        let stub = lock.withLock { () -> Stub? in
            recorded.append(request)
            return stubs.last { request.url.string.contains($0.match) }?.stub
        }
        guard let stub else {
            return eventLoop.makeFailedFuture(
                Abort(.badGateway, reason: "FakeIdPClient has no stub for \(request.url.string)"))
        }
        var headers = HTTPHeaders()
        headers.contentType = .json
        return eventLoop.makeSucceededFuture(
            ClientResponse(status: stub.status, headers: headers, body: ByteBuffer(string: stub.body)))
    }
}

// MARK: - Tests

/// Flow-level tests for the OIDC login path (issue #366): the authorize
/// redirect, callback CSRF/replay rejection, token exchange, JWKS-based
/// ID-token validation (signature, exp, aud, nonce, iss), and JIT user
/// creation — driven through the real HTTP routes with a scripted IdP client.
@Suite("OIDC Auth Flow Tests", .serialized)
final class OIDCAuthFlowTests {

    init() {
        // The token-exchange, UserInfo, and JWKS fetches enforce the same SSRF
        // host allow-list as discovery, so the fake IdP's host must be listed.
        setenv("OIDC_DISCOVERY_ALLOWED_HOSTS", "idp.example.com", 1)
    }

    private let issuer = "https://idp.example.com"
    private let tokenEndpointPath = "https://idp.example.com/token"
    private let jwksPath = "https://idp.example.com/jwks"

    // MARK: Harness

    /// Boots a test app with an org and an enabled provider, and installs the
    /// scripted IdP client as the app's HTTP client.
    private func withFlowApp(
        issuer: String? = "https://idp.example.com",
        discoveryURL: String? = nil,
        _ test: (Application, Organization, OIDCProvider, FakeIdPClient) async throws -> Void
    ) async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "SSO Flow Org")

            let provider = OIDCProvider(
                organizationID: org.id!,
                name: "Flow IdP",
                clientID: "client-abc",
                clientSecret: "s3cret",
                discoveryURL: discoveryURL,
                issuer: issuer,
                authorizationEndpoint: "https://idp.example.com/authorize",
                tokenEndpoint: tokenEndpointPath,
                jwksURI: jwksPath
            )
            try await provider.save(on: app.db)

            let fake = FakeIdPClient(on: app.eventLoopGroup.next())
            app.clients.use { _ in fake }

            try await test(app, org, provider, fake)
        }
    }

    private struct AuthorizeRedirect {
        var state: String
        var nonce: String
        var sessionCookie: String
    }

    /// Hits the authorize endpoint and captures the state/nonce the server
    /// generated plus the session cookie that binds them to this "browser".
    /// `expectNonce` asserts whether a `nonce` is present on the redirect —
    /// providers with `useNonce == false` must omit it.
    private func startLogin(
        app: Application, org: Organization, provider: OIDCProvider, expectNonce: Bool = true
    ) async throws -> AuthorizeRedirect {
        var redirect: AuthorizeRedirect?
        try await app.test(.GET, "/auth/oidc/\(org.id!)/\(provider.id!)/authorize") { res in
            #expect(res.status == .seeOther)

            let location = res.headers.first(name: .location) ?? ""
            let components = URLComponents(string: location)
            let query = components?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

            #expect(location.hasPrefix("https://idp.example.com/authorize"))
            #expect(value("client_id") == "client-abc")
            #expect(value("response_type") == "code")
            #expect(value("redirect_uri")?.contains("/auth/oidc/\(org.id!)/\(provider.id!)/callback") == true)
            #expect((value("nonce") != nil) == expectNonce)

            guard let state = value("state"),
                let cookie = res.headers.setCookie?["vapor-session"]?.string
            else {
                Issue.record("Authorize redirect missing state/session cookie: \(location)")
                return
            }
            redirect = AuthorizeRedirect(state: state, nonce: value("nonce") ?? "", sessionCookie: cookie)
        }
        return try #require(redirect)
    }

    private func callback(
        app: Application,
        org: Organization,
        provider: OIDCProvider,
        code: String = "auth-code-1",
        state: String,
        sessionCookie: String?,
        afterResponse: (TestingHTTPResponse) async throws -> Void
    ) async throws {
        let query = "code=\(code)&state=\(state)"
        try await app.test(.GET, "/auth/oidc/\(org.id!)/\(provider.id!)/callback?\(query)") { req in
            if let sessionCookie {
                var cookies = HTTPCookies()
                cookies["vapor-session"] = HTTPCookies.Value(string: sessionCookie)
                req.headers.cookie = cookies
            }
        } afterResponse: { res in
            try await afterResponse(res)
        }
    }

    private func expectLoginFailedRedirect(_ res: TestingHTTPResponse) {
        #expect(res.status == .seeOther)
        #expect(res.headers.first(name: .location) == "/login?error=oidc_failed")
    }

    private func userCount(on db: Database, subject: String = "sub-123") async throws -> Int {
        try await User.query(on: db).filter(\.$oidcSubject == subject).count()
    }

    // MARK: Happy path + token exchange request shape

    @Test("Full login flow signs in a JIT user and posts a well-formed token exchange")
    func testHappyPathLogin() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            let idToken = try await signIDToken(nonce: login.nonce)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/")
            }

            // JIT-provisioned user linked to the provider, with org membership.
            let user = try await User.query(on: app.db)
                .filter(\.$oidcSubject == "sub-123")
                .first()
            let resolvedUser = try #require(user)
            #expect(resolvedUser.$oidcProvider.id == provider.id)
            #expect(resolvedUser.email == "sso-user@example.com")
            let membership = try await UserOrganization.query(on: app.db)
                .filter(\.$user.$id == resolvedUser.id!)
                .filter(\.$organization.$id == org.id!)
                .first()
            #expect(membership?.role == "member")

            // The token exchange posted the authorization-code grant to the
            // configured endpoint as a URL-encoded form with our credentials.
            let tokenRequests = idp.requests(urlContaining: tokenEndpointPath)
            #expect(tokenRequests.count == 1)
            let tokenRequest = try #require(tokenRequests.first)
            #expect(tokenRequest.method == .POST)
            #expect(tokenRequest.headers.contentType == .urlEncodedForm)
            let form = tokenRequest.body.map { String(buffer: $0) } ?? ""
            let fields = Set(form.split(separator: "&").map(String.init))
            #expect(fields.contains("grant_type=authorization_code"))
            #expect(fields.contains("client_id=client-abc"))
            #expect(fields.contains("client_secret=s3cret"))
            #expect(fields.contains("code=auth-code-1"))
            let redirectField = fields.first { $0.hasPrefix("redirect_uri=") } ?? ""
            #expect(redirectField.contains("callback"))
        }
    }

    @Test("A second login with the same subject reuses the user instead of duplicating it")
    func testRepeatLoginIsIdempotent() async throws {
        try await withFlowApp { app, org, provider, idp in
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            for _ in 0..<2 {
                let login = try await startLogin(app: app, org: org, provider: provider)
                let idToken = try await signIDToken(nonce: login.nonce)
                idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
                try await callback(
                    app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
                ) { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/")
                }
            }

            let count = try await userCount(on: app.db)
            #expect(count == 1)
        }
    }

    // MARK: Callback CSRF / replay

    @Test("Callback with a state that does not match the session is rejected")
    func testStateMismatchRejected() async throws {
        try await withFlowApp { app, org, provider, _ in
            let login = try await startLogin(app: app, org: org, provider: provider)

            try await callback(
                app: app, org: org, provider: provider, state: "forged-state", sessionCookie: login.sessionCookie
            ) { res in
                #expect(res.status == .badRequest)
            }
            let count = try await userCount(on: app.db)
            #expect(count == 0)
        }
    }

    @Test("JWKS fetch for a non-allow-listed host is blocked without any request")
    func testJWKSFetchBlockedByAllowList() async throws {
        try await withFlowApp { app, org, provider, idp in
            // An org admin points the JWKS URI at an internal service. The
            // login must fail and the control plane must never issue the
            // request — the SSRF allow-list covers more than discovery.
            provider.jwksURI = "https://internal-admin.svc.example.org/jwks"
            try await provider.save(on: app.db)

            let login = try await startLogin(app: app, org: org, provider: provider)

            let idToken = try await signIDToken(nonce: login.nonce)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: "internal-admin.svc.example.org", json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                expectLoginFailedRedirect(res)
            }
            #expect(idp.requests(urlContaining: "internal-admin.svc.example.org").isEmpty)
            #expect(try await userCount(on: app.db) == 0)
        }
    }

    @Test("Callback without the initiating session is rejected")
    func testCallbackWithoutSessionRejected() async throws {
        try await withFlowApp { app, org, provider, _ in
            let login = try await startLogin(app: app, org: org, provider: provider)

            // Correct state but no session cookie: nothing ties the request
            // to the browser that started the flow.
            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: nil
            ) { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Callback for a different provider than the session initiated is rejected")
    func testProviderMismatchRejected() async throws {
        try await withFlowApp { app, org, provider, _ in
            let other = OIDCProvider(
                organizationID: org.id!,
                name: "Other IdP",
                clientID: "client-other",
                clientSecret: "s3cret",
                authorizationEndpoint: "https://other.example.com/authorize",
                tokenEndpoint: "https://other.example.com/token",
                jwksURI: "https://other.example.com/jwks"
            )
            try await other.save(on: app.db)

            let login = try await startLogin(app: app, org: org, provider: provider)

            try await callback(
                app: app, org: org, provider: other, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Replaying a consumed callback is rejected")
    func testCallbackReplayRejected() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            let idToken = try await signIDToken(nonce: login.nonce)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/")
            }

            // The state was cleared from the session on success, so the same
            // redirect URL cannot be replayed.
            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: Token exchange error handling

    @Test("A failing token endpoint aborts the login")
    func testTokenEndpointErrorFailsLogin() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            idp.stub(
                urlContaining: tokenEndpointPath, status: .badRequest,
                json: #"{"error":"invalid_grant"}"#)

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                self.expectLoginFailedRedirect(res)
            }
            let count = try await userCount(on: app.db)
            #expect(count == 0)
        }
    }

    @Test("A provider without a token endpoint aborts the login")
    func testMissingTokenEndpointFailsLogin() async throws {
        try await withFlowApp { app, org, provider, _ in
            let login = try await startLogin(app: app, org: org, provider: provider)

            provider.tokenEndpoint = nil
            try await provider.save(on: app.db)

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                self.expectLoginFailedRedirect(res)
            }
        }
    }

    // MARK: ID-token validation

    @Test("An ID token signed by a different key is rejected")
    func testBadSignatureRejected() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            // Signed with the wrong private key but claiming the trusted kid,
            // so validation must fail on the signature itself.
            let idToken = try await signIDToken(nonce: login.nonce, privateKeyPEM: TestRSAKeys.otherPrivateKeyPEM)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                self.expectLoginFailedRedirect(res)
            }
            let count = try await userCount(on: app.db)
            #expect(count == 0)
        }
    }

    @Test("An ID token whose kid is absent from the JWKS is rejected")
    func testUnknownKeyIDRejected() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            let idToken = try await signIDToken(nonce: login.nonce)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON(kid: "some-other-key"))

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                self.expectLoginFailedRedirect(res)
            }
        }
    }

    @Test("An expired ID token is rejected")
    func testExpiredTokenRejected() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            let idToken = try await signIDToken(expiresIn: -60, nonce: login.nonce)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                self.expectLoginFailedRedirect(res)
            }
        }
    }

    @Test("An ID token for a different audience is rejected")
    func testAudienceMismatchRejected() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            let idToken = try await signIDToken(aud: "someone-elses-client", nonce: login.nonce)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                self.expectLoginFailedRedirect(res)
            }
        }
    }

    @Test("An ID token whose aud is a single-element JSON array is accepted")
    func testAudienceArrayAccepted() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            // Discord (and others) encode `aud` as an array even for a single
            // audience. RFC 7519 §4.1.3 permits this, and our client ID is the
            // sole value, so the login must succeed rather than fail to decode.
            let idToken = try await signIDTokenArrayAud(aud: ["client-abc"], nonce: login.nonce)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/")
            }

            let count = try await userCount(on: app.db)
            #expect(count == 1)
        }
    }

    @Test("An ID token that also lists an untrusted co-audience is rejected")
    func testExtraAudienceRejected() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            // Our client ID is present, but so is another audience we don't
            // trust. OIDC Core §3.1.3.7 requires rejecting untrusted extra
            // audiences, and we keep no allow-list, so this must fail.
            let idToken = try await signIDTokenArrayAud(
                aud: ["client-abc", "another-client"], nonce: login.nonce)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                self.expectLoginFailedRedirect(res)
            }
            let count = try await userCount(on: app.db)
            #expect(count == 0)
        }
    }

    @Test("An ID token whose azp is not our client ID is rejected")
    func testAuthorizedPartyMismatchRejected() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            // aud is valid (our client ID) but azp names a different party.
            // OIDC Core §3.1.3.7 step 5 requires azp, when present, to be us.
            let idToken = try await signIDToken(
                aud: "client-abc", azp: "another-client", nonce: login.nonce)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                self.expectLoginFailedRedirect(res)
            }
            let count = try await userCount(on: app.db)
            #expect(count == 0)
        }
    }

    @Test("An ID token whose azp is our client ID is accepted")
    func testAuthorizedPartyMatchAccepted() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            let idToken = try await signIDToken(
                aud: "client-abc", azp: "client-abc", nonce: login.nonce)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/")
            }

            let count = try await userCount(on: app.db)
            #expect(count == 1)
        }
    }

    @Test("An ID token whose array aud omits our client ID is rejected")
    func testAudienceArrayMismatchRejected() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            let idToken = try await signIDTokenArrayAud(
                aud: ["someone-else", "another-one"], nonce: login.nonce)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                self.expectLoginFailedRedirect(res)
            }
            let count = try await userCount(on: app.db)
            #expect(count == 0)
        }
    }

    @Test("An ID token with an empty aud array is rejected, not crashed on")
    func testEmptyAudienceRejected() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            // `aud: []` must fail the login cleanly. It must NOT trap the
            // process during claim decode (JWTKit's AudienceClaim would).
            let idToken = try await signIDTokenArrayAud(aud: [], nonce: login.nonce)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                self.expectLoginFailedRedirect(res)
            }
            let count = try await userCount(on: app.db)
            #expect(count == 0)
        }
    }

    @Test("A nonce-requiring provider rejects an ID token that omits the nonce")
    func testMissingNonceRejectedWhenRequired() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            // Provider defaults to useNonce == true, so a token with no nonce
            // (Discord's behavior) must be rejected — the compliant path.
            let idToken = try await signIDToken(nonce: nil)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                self.expectLoginFailedRedirect(res)
            }
            let count = try await userCount(on: app.db)
            #expect(count == 0)
        }
    }

    @Test("A provider with useNonce disabled logs in even when the id_token omits nonce")
    func testNonceDisabledAllowsMissingNonce() async throws {
        try await withFlowApp { app, org, provider, idp in
            // Discord accepts but never echoes the nonce; disabling it makes
            // strato neither send nor require one.
            provider.useNonce = false
            try await provider.save(on: app.db)

            let login = try await startLogin(
                app: app, org: org, provider: provider, expectNonce: false)

            let idToken = try await signIDToken(nonce: nil)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/")
            }
            let count = try await userCount(on: app.db)
            #expect(count == 1)
        }
    }

    @Test("Disabling nonce clears a stale nonce left in the session by a prior flow")
    func testDisablingNonceClearsStaleSessionNonce() async throws {
        try await withFlowApp { app, org, provider, idp in
            // 1) A nonce-requiring login seeds oidc_nonce in the session, then
            //    is abandoned (no callback).
            let first = try await startLogin(app: app, org: org, provider: provider)

            // 2) Disable nonce, then start a fresh login reusing the SAME
            //    browser session (same cookie).
            provider.useNonce = false
            try await provider.save(on: app.db)

            var second: AuthorizeRedirect?
            try await app.test(.GET, "/auth/oidc/\(org.id!)/\(provider.id!)/authorize") { req in
                var cookies = HTTPCookies()
                cookies["vapor-session"] = HTTPCookies.Value(string: first.sessionCookie)
                req.headers.cookie = cookies
            } afterResponse: { res in
                #expect(res.status == .seeOther)
                let location = res.headers.first(name: .location) ?? ""
                let query = URLComponents(string: location)?.queryItems ?? []
                func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
                #expect(value("nonce") == nil)  // the new flow requests no nonce
                let cookie = res.headers.setCookie?["vapor-session"]?.string ?? first.sessionCookie
                second = AuthorizeRedirect(state: value("state") ?? "", nonce: "", sessionCookie: cookie)
            }
            let login = try #require(second)

            // 3) A nonce-less token must log in — the stale nonce from step 1
            //    must have been cleared, not validated against.
            let idToken = try await signIDToken(nonce: nil)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/")
            }
            let count = try await userCount(on: app.db)
            #expect(count == 1)
        }
    }

    @Test("An ID token with the wrong nonce is rejected")
    func testNonceMismatchRejected() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            let idToken = try await signIDToken(nonce: "replayed-nonce")
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                self.expectLoginFailedRedirect(res)
            }
            let count = try await userCount(on: app.db)
            #expect(count == 0)
        }
    }

    @Test("An ID token from a different issuer is rejected")
    func testIssuerMismatchRejected() async throws {
        try await withFlowApp { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            let idToken = try await signIDToken(iss: "https://evil.example.com", nonce: login.nonce)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                self.expectLoginFailedRedirect(res)
            }
        }
    }

    @Test("A discovery-configured provider with no resolved issuer fails closed")
    func testMissingIssuerFailsClosedForDiscoveryProviders() async throws {
        try await withFlowApp(
            issuer: nil,
            discoveryURL: "https://idp.example.com/.well-known/openid-configuration"
        ) { app, org, provider, idp in
            let login = try await startLogin(app: app, org: org, provider: provider)

            // Even a perfectly valid token must be refused: the provider was
            // configured via discovery but its issuer was never resolved, so
            // the iss claim cannot be verified.
            let idToken = try await signIDToken(nonce: login.nonce)
            idp.stub(urlContaining: tokenEndpointPath, json: tokenResponseJSON(idToken: idToken))
            idp.stub(urlContaining: jwksPath, json: jwksJSON())

            try await callback(
                app: app, org: org, provider: provider, state: login.state, sessionCookie: login.sessionCookie
            ) { res in
                self.expectLoginFailedRedirect(res)
            }
        }
    }
}
