import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

// MARK: - SET crafting helpers

/// Base64url-encode without padding (JWT segment encoding).
private func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Craft an unsigned Security Event Token. Only parses when the app runs
/// with SSF_ALLOW_UNVERIFIED_TOKENS (honored under .testing only).
private func makeUnsignedSET(
    iss: String,
    events: [String: [String: Any]],
    subID: [String: Any]? = nil,
    jti: String = UUID().uuidString
) throws -> String {
    let header: [String: Any] = ["alg": "none", "typ": "secevent+jwt"]
    var payload: [String: Any] = [
        "iss": iss,
        "jti": jti,
        "iat": Int(Date().timeIntervalSince1970),
        "events": events,
    ]
    if let subID {
        payload["sub_id"] = subID
    }
    let headerData = try JSONSerialization.data(withJSONObject: header)
    let payloadData = try JSONSerialization.data(withJSONObject: payload)
    return "\(base64url(headerData)).\(base64url(payloadData)).\(base64url(Data("sig".utf8)))"
}

private let secEventMediaType = HTTPMediaType(type: "application", subType: "secevent+jwt")

private let sessionRevokedType = "https://schemas.openid.net/secevent/caep/event-type/session-revoked"
private let credentialCompromiseType = "https://schemas.openid.net/secevent/risc/event-type/credential-compromise"
private let accountDisabledType = "https://schemas.openid.net/secevent/risc/event-type/account-disabled"
private let accountEnabledType = "https://schemas.openid.net/secevent/risc/event-type/account-enabled"

// MARK: - Shared fixtures

private struct SSFFixture {
    let user: User
    let organization: Organization
    let stream: SSFStream
    let pushToken: String
    let apiToken: String
}

/// A user + org + registered-enough push stream, wired the way the push
/// endpoint expects (hashed bearer token, push delivery, enabled).
private func makePushFixture(
    _ app: Application, transmitterURL: String = "https://idp.example.com"
) async throws -> SSFFixture {
    let builder = TestDataBuilder(db: app.db)
    let user = try await builder.createUser(username: "ssfuser", email: "ssf@example.com")
    let org = try await builder.createOrganization(name: "SSF Org")
    try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
    let apiToken = try await user.generateAPIKey(on: app.db)

    let stream = SSFStream(
        organizationID: org.id!,
        name: "IdP events",
        transmitterURL: transmitterURL,
        deliveryMethod: .push,
        createdByID: user.id!
    )
    let pushToken = SSFStream.generatePushToken()
    stream.pushTokenHash = SSFStream.hashPushToken(pushToken)
    stream.pushTokenPrefix = SSFStream.extractPushTokenPrefix(pushToken)
    stream.remoteStreamID = "remote-stream-1"
    try await stream.save(on: app.db)

    return SSFFixture(
        user: user, organization: org, stream: stream, pushToken: pushToken, apiToken: apiToken)
}

// MARK: - Push delivery endpoint

@Suite("SSF Push Delivery Tests", .serialized)
final class SSFPushDeliveryTests {
    init() {
        // Honored only under .testing: lets tests deliver unsigned SETs
        // without standing up a JWKS-serving mock transmitter.
        setenv("SSF_ALLOW_UNVERIFIED_TOKENS", "true", 1)
    }

    private func deliver(
        _ app: Application,
        streamID: UUID,
        token: String?,
        body: String,
        contentType: HTTPMediaType = secEventMediaType,
        expect status: HTTPResponseStatus
    ) async throws {
        try await app.test(.POST, "/ssf/events/\(streamID.uuidString)") { req in
            if let token {
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }
            req.headers.contentType = contentType
            req.body = ByteBufferAllocator().buffer(string: body)
        } afterResponse: { res in
            #expect(res.status == status)
        }
    }

    @Test("Valid session-revoked SET revokes the user's sessions")
    func sessionRevokedBumpsEpoch() async throws {
        try await withTestApp { app in
            let fixture = try await makePushFixture(app)
            let set = try makeUnsignedSET(
                iss: "https://idp.example.com",
                events: [sessionRevokedType: [:]],
                subID: ["format": "email", "email": "ssf@example.com"]
            )
            try await self.deliver(
                app, streamID: fixture.stream.id!, token: fixture.pushToken, body: set,
                expect: .accepted)

            let user = try #require(try await User.find(fixture.user.id, on: app.db))
            #expect(user.sessionEpoch == 1)
            #expect(user.disabledAt == nil)

            let audited = try await AuditEvent.query(on: app.db)
                .filter(\.$eventType == "ssf.sessions_revoked").count()
            #expect(audited == 1)

            let stream = try #require(try await SSFStream.find(fixture.stream.id, on: app.db))
            #expect(stream.lastEventAt != nil)
        }
    }

    @Test("Credential compromise revokes sessions and deactivates API keys")
    func credentialCompromiseDeactivatesKeys() async throws {
        try await withTestApp { app in
            let fixture = try await makePushFixture(app)
            let set = try makeUnsignedSET(
                iss: "https://idp.example.com",
                events: [credentialCompromiseType: ["credential_type": "password"]],
                subID: ["format": "email", "email": "ssf@example.com"]
            )
            try await self.deliver(
                app, streamID: fixture.stream.id!, token: fixture.pushToken, body: set,
                expect: .accepted)

            let user = try #require(try await User.find(fixture.user.id, on: app.db))
            #expect(user.sessionEpoch == 1)

            let activeKeys = try await APIKey.query(on: app.db)
                .filter(\.$user.$id == fixture.user.id!)
                .filter(\.$isActive == true)
                .count()
            #expect(activeKeys == 0)
        }
    }

    @Test("Account disabled and enabled toggle the user's disabled state")
    func accountDisableEnableCycle() async throws {
        try await withTestApp { app in
            let fixture = try await makePushFixture(app)

            let disable = try makeUnsignedSET(
                iss: "https://idp.example.com",
                events: [accountDisabledType: ["reason": "hijacking"]],
                subID: ["format": "email", "email": "ssf@example.com"]
            )
            try await self.deliver(
                app, streamID: fixture.stream.id!, token: fixture.pushToken, body: disable,
                expect: .accepted)
            var user = try #require(try await User.find(fixture.user.id, on: app.db))
            #expect(user.disabledAt != nil)
            #expect(user.sessionEpoch == 1)

            let enable = try makeUnsignedSET(
                iss: "https://idp.example.com",
                events: [accountEnabledType: [:]],
                subID: ["format": "email", "email": "ssf@example.com"]
            )
            try await self.deliver(
                app, streamID: fixture.stream.id!, token: fixture.pushToken, body: enable,
                expect: .accepted)
            user = try #require(try await User.find(fixture.user.id, on: app.db))
            #expect(user.disabledAt == nil)
        }
    }

    @Test("Subjects outside the stream's organization are not acted on")
    func subjectOutsideOrgIgnored() async throws {
        try await withTestApp { app in
            let fixture = try await makePushFixture(app)
            let outsider = try await TestDataBuilder(db: app.db)
                .createUser(username: "outsider", email: "outsider@example.com")

            let set = try makeUnsignedSET(
                iss: "https://idp.example.com",
                events: [sessionRevokedType: [:]],
                subID: ["format": "email", "email": "outsider@example.com"]
            )
            // Still 202: the SET was valid; there was just nothing to do.
            try await self.deliver(
                app, streamID: fixture.stream.id!, token: fixture.pushToken, body: set,
                expect: .accepted)

            let user = try #require(try await User.find(outsider.id, on: app.db))
            #expect(user.sessionEpoch == 0)

            let unmatched = try await AuditEvent.query(on: app.db)
                .filter(\.$eventType == "ssf.subject_unmatched").count()
            #expect(unmatched == 1)
        }
    }

    @Test("Push delivery requires the stream's bearer token")
    func rejectsBadBearerToken() async throws {
        try await withTestApp { app in
            let fixture = try await makePushFixture(app)
            let set = try makeUnsignedSET(
                iss: "https://idp.example.com", events: [sessionRevokedType: [:]])

            try await self.deliver(
                app, streamID: fixture.stream.id!, token: nil, body: set, expect: .unauthorized)
            try await self.deliver(
                app, streamID: fixture.stream.id!, token: "ssf_wrong", body: set,
                expect: .unauthorized)

            let user = try #require(try await User.find(fixture.user.id, on: app.db))
            #expect(user.sessionEpoch == 0)
        }
    }

    @Test("Push delivery enforces the SET content type and issuer")
    func rejectsBadContentTypeAndIssuer() async throws {
        try await withTestApp { app in
            let fixture = try await makePushFixture(app)
            let set = try makeUnsignedSET(
                iss: "https://idp.example.com", events: [sessionRevokedType: [:]])

            try await self.deliver(
                app, streamID: fixture.stream.id!, token: fixture.pushToken, body: set,
                contentType: .json, expect: .badRequest)

            let wrongIssuer = try makeUnsignedSET(
                iss: "https://evil.example.com", events: [sessionRevokedType: [:]])
            try await self.deliver(
                app, streamID: fixture.stream.id!, token: fixture.pushToken, body: wrongIssuer,
                expect: .badRequest)

            try await self.deliver(
                app, streamID: fixture.stream.id!, token: fixture.pushToken, body: "not-a-jwt",
                expect: .badRequest)
        }
    }

    @Test("Unknown streams and disabled streams reject push delivery")
    func rejectsUnknownAndDisabledStreams() async throws {
        try await withTestApp { app in
            let fixture = try await makePushFixture(app)
            let set = try makeUnsignedSET(
                iss: "https://idp.example.com", events: [sessionRevokedType: [:]])

            try await self.deliver(
                app, streamID: UUID(), token: fixture.pushToken, body: set, expect: .notFound)

            fixture.stream.enabled = false
            try await fixture.stream.save(on: app.db)
            try await self.deliver(
                app, streamID: fixture.stream.id!, token: fixture.pushToken, body: set,
                expect: .notFound)
        }
    }
}

// MARK: - Stream management API

@Suite("SSF Stream API Tests", .serialized)
final class SSFStreamAPITests {
    @Test("Stream CRUD via the organization-scoped API")
    func streamCRUD() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "ssfadmin", email: "admin@example.com")
            let org = try await builder.createOrganization(name: "CRUD Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            let token = try await user.generateAPIKey(on: app.db)
            let base = "/api/organizations/\(org.id!.uuidString)/ssf-streams"

            var streamID: UUID?
            try await app.test(.POST, base) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSSFStreamRequest(
                        name: "Okta",
                        description: "Workforce IdP",
                        transmitterURL: "https://idp.example.com",
                        authToken: "management-secret",
                        expectedIssuer: nil,
                        expectedAudience: ["https://strato.example.com"],
                        deliveryMethod: .push,
                        eventsRequested: [sessionRevokedType]
                    ))
            } afterResponse: { res in
                #expect(res.status == .created)
                let body = try res.content.decode(SSFStreamResponse.self)
                streamID = body.id
                #expect(body.name == "Okta")
                #expect(body.deliveryMethod == "push")
                #expect(body.registered == false)
                #expect(body.eventsRequested == [sessionRevokedType])
                // The management auth token must never round-trip.
                #expect(!res.body.string.contains("management-secret"))
            }
            let id = try #require(streamID)

            try await app.test(.GET, base) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode([SSFStreamResponse].self)
                #expect(body.count == 1)
            }

            try await app.test(.PUT, "\(base)/\(id.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateSSFStreamRequest(
                        name: "Okta prod",
                        description: nil,
                        authToken: nil,
                        expectedIssuer: nil,
                        expectedAudience: nil,
                        eventsRequested: nil,
                        enabled: false
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(SSFStreamResponse.self)
                #expect(body.name == "Okta prod")
                #expect(body.enabled == false)
            }

            try await app.test(.DELETE, "\(base)/\(id.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            let remaining = try await SSFStream.query(on: app.db).count()
            #expect(remaining == 0)
        }
    }

    @Test("Stream creation validates the transmitter URL")
    func createRejectsInvalidTransmitterURL() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "ssfadmin2", email: "a2@example.com")
            let org = try await builder.createOrganization(name: "URL Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            let token = try await user.generateAPIKey(on: app.db)

            try await app.test(.POST, "/api/organizations/\(org.id!.uuidString)/ssf-streams") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSSFStreamRequest(
                        name: "bad",
                        description: nil,
                        transmitterURL: "not a url",
                        authToken: nil,
                        expectedIssuer: nil,
                        expectedAudience: nil,
                        deliveryMethod: .poll,
                        eventsRequested: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .unprocessableEntity)
            }
        }
    }

    @Test("Stream mutations require organization admin")
    func mutationsRequireAdmin() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "member", email: "m@example.com")
            let org = try await builder.createOrganization(name: "Denied Org")
            try await builder.addUserToOrganization(user: user, organization: org)
            let token = try await user.generateAPIKey(on: app.db)

            app.spicedbMockAllows = false
            try await app.test(.POST, "/api/organizations/\(org.id!.uuidString)/ssf-streams") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSSFStreamRequest(
                        name: "nope",
                        description: nil,
                        transmitterURL: "https://idp.example.com",
                        authToken: nil,
                        expectedIssuer: nil,
                        expectedAudience: nil,
                        deliveryMethod: .push,
                        eventsRequested: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }
}

// MARK: - UserSecurityMiddleware

@Suite("User Security Middleware Tests", .serialized)
final class UserSecurityMiddlewareTests {
    private struct OKResponder: AsyncResponder {
        func respond(to request: Request) async throws -> Response {
            Response(status: .ok)
        }
    }

    /// Run `UserSecurityMiddleware` on a fresh request, wrapped in Vapor's
    /// sessions middleware (accessing `req.session` without it is a fatal
    /// error). `setup` runs inside the session context, standing in for the
    /// authenticators and login handlers.
    private func respond(
        _ app: Application,
        setup: @escaping @Sendable (Request) async throws -> Void
    ) async throws -> Response {
        let req = Request(
            application: app, method: .GET, url: URI(path: "/api/vms"),
            on: app.eventLoopGroup.next())
        let inner = BasicResponder { request in
            let promise = request.eventLoop.makePromise(of: Response.self)
            promise.completeWithTask {
                try await setup(request)
                return try await UserSecurityMiddleware().respond(to: request, chainingTo: OKResponder())
            }
            return promise.futureResult
        }
        return try await app.sessions.middleware.respond(to: req, chainingTo: inner).get()
    }

    @Test("Requests pass when the session epoch matches")
    func matchingEpochPasses() async throws {
        try await withTestApp { app in
            let user = try await TestDataBuilder(db: app.db)
                .createUser(username: "epoch0", email: "e0@example.com")
            let res = try await self.respond(app) { req in
                req.auth.login(user)
                req.session.authenticate(user)
                req.stampSessionEpoch(for: user)
            }
            #expect(res.status == .ok)
        }
    }

    @Test("A bumped session epoch revokes existing sessions")
    func bumpedEpochRevokesSession() async throws {
        try await withTestApp { app in
            let user = try await TestDataBuilder(db: app.db)
                .createUser(username: "epoch1", email: "e1@example.com")
            let res = try await self.respond(app) { req in
                req.auth.login(user)
                req.session.authenticate(user)
                req.stampSessionEpoch(for: user)
                // The signal handler bumps the epoch after login.
                user.sessionEpoch += 1
                try await user.save(on: app.db)
            }
            #expect(res.status == .unauthorized)
        }
    }

    @Test("Sessions with no epoch stamp count as epoch zero")
    func missingStampCountsAsZero() async throws {
        try await withTestApp { app in
            let user = try await TestDataBuilder(db: app.db)
                .createUser(username: "legacy", email: "legacy@example.com")

            // No stamp: a pre-feature session. Epoch 0 still matches.
            let ok = try await self.respond(app) { req in
                req.auth.login(user)
                req.session.authenticate(user)
            }
            #expect(ok.status == .ok)

            user.sessionEpoch = 1
            try await user.save(on: app.db)
            let revoked = try await self.respond(app) { req in
                req.auth.login(user)
                req.session.authenticate(user)
            }
            #expect(revoked.status == .unauthorized)
        }
    }

    @Test("Disabled accounts are rejected on any authenticated request")
    func disabledAccountRejected() async throws {
        try await withTestApp { app in
            let user = try await TestDataBuilder(db: app.db)
                .createUser(username: "disabled", email: "d@example.com")
            user.disabledAt = Date()
            try await user.save(on: app.db)

            // No session at all — the API-key path is rejected too.
            let res = try await self.respond(app) { req in
                req.auth.login(user)
            }
            #expect(res.status == .forbidden)
        }
    }

    @Test("API-key requests survive an epoch mismatch and re-stamp the session")
    func apiKeyRequestsRestampStaleSessions() async throws {
        try await withTestApp { app in
            let user = try await TestDataBuilder(db: app.db)
                .createUser(username: "keyed", email: "k@example.com")
            let res = try await self.respond(app) { req in
                req.auth.login(user)
                req.session.authenticate(user)
                req.stampSessionEpoch(for: user)
                user.sessionEpoch = 3
                try await user.save(on: app.db)
                req.apiKey = APIKey()  // marks the request bearer-authenticated
            }
            #expect(res.status == .ok)
        }
    }

    @Test("End to end: a delivered session-revoked SET locks out the session")
    func endToEndSessionRevocation() async throws {
        setenv("SSF_ALLOW_UNVERIFIED_TOKENS", "true", 1)
        try await withTestApp { app in
            let fixture = try await makePushFixture(app)

            // A logged-in browser session established before the signal passes.
            let user = fixture.user
            let ok = try await self.respond(app) { req in
                req.auth.login(user)
                req.session.authenticate(user)
                req.stampSessionEpoch(for: user)
            }
            #expect(ok.status == .ok)

            let set = try makeUnsignedSET(
                iss: "https://idp.example.com",
                events: [sessionRevokedType: [:]],
                subID: ["format": "email", "email": "ssf@example.com"]
            )
            try await app.test(.POST, "/ssf/events/\(fixture.stream.id!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.pushToken)
                req.headers.contentType = secEventMediaType
                req.body = ByteBufferAllocator().buffer(string: set)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            // The same session (epoch stamp 0) is now revoked.
            let refreshed = try #require(try await User.find(fixture.user.id, on: app.db))
            let denied = try await self.respond(app) { req in
                req.auth.login(refreshed)
                req.session.authenticate(refreshed)
                req.session.data[UserSecurityMiddleware.sessionEpochKey] = "0"
            }
            #expect(denied.status == .unauthorized)
        }
    }
}
