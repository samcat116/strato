import ControlPlanePostgres
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport
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
    let stream: SSFStreamSnapshot
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
    let apiToken = try await user.generateAPIKey(on: app)

    let created = try await app.ssfStreamsPersistence.create(
        SSFStreamWrite(
            organizationID: org.id!,
            name: "IdP events",
            transmitterURL: transmitterURL,
            deliveryMethod: .push,
            createdByID: user.id!
        )
    )
    let pushToken = SSFPushCredential.generatePushToken()
    let stream = try #require(
        try await app.ssfStreamsPersistence.completeRegistration(
            id: created.id,
            remoteStreamID: "remote-stream-1",
            pollEndpoint: nil,
            pushTokenHash: SSFPushCredential.hashPushToken(pushToken),
            pushTokenPrefix: SSFPushCredential.extractPushTokenPrefix(pushToken)
        )
    )

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
        setenv("SSF_TRANSMITTER_ALLOWED_SUFFIXES", ".example.com", 1)
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
                app, streamID: fixture.stream.id, token: fixture.pushToken, body: set,
                expect: .accepted)

            let user = try #require(try await User.find(fixture.user.id, on: app.db))
            #expect(user.sessionEpoch == 1)
            #expect(user.disabledAt == nil)

            let audited = try await app.audit.events.events(
                matching: AuditEventFilter(eventType: "ssf.sessions_revoked"),
                limit: 1
            ).total
            #expect(audited == 1)

            let stream = try #require(
                try await app.ssfStreamsPersistence.stream(id: fixture.stream.id)
            )
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
                app, streamID: fixture.stream.id, token: fixture.pushToken, body: set,
                expect: .accepted)

            let user = try #require(try await User.find(fixture.user.id, on: app.db))
            #expect(user.sessionEpoch == 1)

            let activeKeys = try await app.apiKeysPersistence.keys(
                userID: fixture.user.id!
            ).filter(\.isActive).count
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
                app, streamID: fixture.stream.id, token: fixture.pushToken, body: disable,
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
                app, streamID: fixture.stream.id, token: fixture.pushToken, body: enable,
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
                app, streamID: fixture.stream.id, token: fixture.pushToken, body: set,
                expect: .accepted)

            let user = try #require(try await User.find(outsider.id, on: app.db))
            #expect(user.sessionEpoch == 0)

            let unmatched = try await app.audit.events.events(
                matching: AuditEventFilter(eventType: "ssf.subject_unmatched"),
                limit: 1
            ).total
            #expect(unmatched == 1)
        }
    }

    @Test("iss_sub subjects resolve scoped to the issuer's provider and organization")
    func issSubScopedToIssuer() async throws {
        try await withTestApp { app in
            let fixture = try await makePushFixture(app)
            let builder = TestDataBuilder(db: app.db)

            // Same OIDC `sub` at two different issuers; only the provider for
            // the stream's transmitter (and organization) may match.
            let provider = try await app.oidcProvidersPersistence.create(OIDCProviderWrite(
                organizationID: fixture.organization.id!,
                name: "IdP",
                clientID: "client",
                encryptedClientSecret: "secret",
                discoveryURL: "https://idp.example.com/.well-known/openid-configuration"
            ))

            let otherOrg = try await builder.createOrganization(name: "Other Org")
            let otherProvider = try await app.oidcProvidersPersistence.create(OIDCProviderWrite(
                organizationID: otherOrg.id!,
                name: "Other IdP",
                clientID: "client",
                encryptedClientSecret: "secret",
                discoveryURL: "https://other-idp.example.com/.well-known/openid-configuration"
            ))

            try await fixture.user.linkedToOIDCProvider(provider.id, subject: "shared-sub").save(on: app.db)
            let otherUser = try await builder.createUser(username: "other", email: "other@example.com")
            try await builder.addUserToOrganization(user: otherUser, organization: otherOrg)
            try await otherUser.linkedToOIDCProvider(otherProvider.id, subject: "shared-sub").save(on: app.db)

            let set = try makeUnsignedSET(
                iss: "https://idp.example.com",
                events: [sessionRevokedType: [:]],
                subID: ["format": "iss_sub", "iss": "https://idp.example.com", "sub": "shared-sub"]
            )
            try await self.deliver(
                app, streamID: fixture.stream.id, token: fixture.pushToken, body: set,
                expect: .accepted)

            let target = try #require(try await User.find(fixture.user.id, on: app.db))
            #expect(target.sessionEpoch == 1)
            let bystander = try #require(try await User.find(otherUser.id, on: app.db))
            #expect(bystander.sessionEpoch == 0)

            // A foreign issuer with the same sub matches no provider in this
            // stream's organization: nothing happens.
            let foreign = try makeUnsignedSET(
                iss: "https://idp.example.com",
                events: [sessionRevokedType: [:]],
                subID: [
                    "format": "iss_sub", "iss": "https://other-idp.example.com", "sub": "shared-sub",
                ]
            )
            try await self.deliver(
                app, streamID: fixture.stream.id, token: fixture.pushToken, body: foreign,
                expect: .accepted)
            let unchanged = try #require(try await User.find(fixture.user.id, on: app.db))
            #expect(unchanged.sessionEpoch == 1)
        }
    }

    @Test("Push delivery requires the stream's bearer token")
    func rejectsBadBearerToken() async throws {
        try await withTestApp { app in
            let fixture = try await makePushFixture(app)
            let set = try makeUnsignedSET(
                iss: "https://idp.example.com", events: [sessionRevokedType: [:]])

            try await self.deliver(
                app, streamID: fixture.stream.id, token: nil, body: set, expect: .unauthorized)
            try await self.deliver(
                app, streamID: fixture.stream.id, token: "ssf_wrong", body: set,
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
                app, streamID: fixture.stream.id, token: fixture.pushToken, body: set,
                contentType: .json, expect: .badRequest)

            let wrongIssuer = try makeUnsignedSET(
                iss: "https://evil.example.com", events: [sessionRevokedType: [:]])
            try await self.deliver(
                app, streamID: fixture.stream.id, token: fixture.pushToken, body: wrongIssuer,
                expect: .badRequest)

            try await self.deliver(
                app, streamID: fixture.stream.id, token: fixture.pushToken, body: "not-a-jwt",
                expect: .badRequest)
        }
    }

    @Test("Unknown, disabled, and unregistered streams reject push delivery")
    func rejectsUnknownAndDisabledStreams() async throws {
        try await withTestApp { app in
            let fixture = try await makePushFixture(app)
            let set = try makeUnsignedSET(
                iss: "https://idp.example.com", events: [sessionRevokedType: [:]])

            try await self.deliver(
                app, streamID: UUID(), token: fixture.pushToken, body: set, expect: .notFound)

            // Unregistered (e.g. a failed re-register): the old token must
            // stop working even if it were still stored.
            _ = try await app.ssfStreamsPersistence.clearRegistration(id: fixture.stream.id)
            try await self.deliver(
                app, streamID: fixture.stream.id, token: fixture.pushToken, body: set,
                expect: .notFound)

            _ = try await app.ssfStreamsPersistence.completeRegistration(
                id: fixture.stream.id,
                remoteStreamID: "remote-stream-1",
                pollEndpoint: nil,
                pushTokenHash: SSFPushCredential.hashPushToken(fixture.pushToken),
                pushTokenPrefix: SSFPushCredential.extractPushTokenPrefix(fixture.pushToken)
            )
            _ = try await app.ssfStreamsPersistence.updateOwnedStream(
                id: fixture.stream.id,
                organizationID: fixture.stream.organizationID,
                changes: SSFStreamChanges(enabled: false)
            )
            try await self.deliver(
                app, streamID: fixture.stream.id, token: fixture.pushToken, body: set,
                expect: .notFound)
        }
    }

    @Test("Poll endpoints outside the allow-list are never polled")
    func pollEndpointOutsideAllowListRejected() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "polluser", email: "poll@example.com")
            let org = try await builder.createOrganization(name: "Poll Org")
            try await builder.addUserToOrganization(user: user, organization: org)

            // A stored endpoint pointing at a metadata service — as a
            // malicious transmitter could have returned before validation
            // existed — must be rejected at poll time.
            let created = try await app.ssfStreamsPersistence.create(
                SSFStreamWrite(
                    organizationID: org.id!,
                    name: "poll",
                    transmitterURL: "https://idp.example.com",
                    deliveryMethod: .poll,
                    createdByID: user.id!
                )
            )
            let stream = try #require(
                try await app.ssfStreamsPersistence.completeRegistration(
                    id: created.id,
                    remoteStreamID: "remote-poll-1",
                    pollEndpoint: "https://169.254.169.254/poll",
                    pushTokenHash: nil,
                    pushTokenPrefix: nil
                )
            )

            do {
                _ = try await app.ssf.pollStream(stream)
                Issue.record("Expected poll endpoint validation to throw")
            } catch let abort as Abort {
                #expect(abort.status == .unprocessableEntity)
            }
        }
    }
}

// MARK: - Stream management API

@Suite("SSF Stream API Tests", .serialized)
final class SSFStreamAPITests {
    init() {
        setenv("SSF_TRANSMITTER_ALLOWED_SUFFIXES", ".example.com", 1)
    }

    @Test("Stream CRUD via the organization-scoped API")
    func streamCRUD() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "ssfadmin", email: "admin@example.com")
            let org = try await builder.createOrganization(name: "CRUD Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            let token = try await user.generateAPIKey(on: app)
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
            #expect(try await app.ssfStreamsPersistence.stream(id: id) == nil)
        }
    }

    @Test("Management auth tokens are stored encrypted at rest and re-encrypted on update")
    func authTokenEncryptedAtRest() async throws {
        try await withTestApp { app in
            let key = try SecretsEncryptionService.parseKey(String(repeating: "ef", count: 32))
            app.secretsEncryption = SecretsEncryptionService(key: key)

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "ssfenc", email: "enc@example.com")
            let org = try await builder.createOrganization(name: "Enc Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            let token = try await user.generateAPIKey(on: app)
            let base = "/api/organizations/\(org.id!.uuidString)/ssf-streams"

            var streamID: UUID?
            try await app.test(.POST, base) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSSFStreamRequest(
                        name: "Okta",
                        description: nil,
                        transmitterURL: "https://idp.example.com",
                        authToken: "management-secret-original",
                        expectedIssuer: nil,
                        expectedAudience: nil,
                        deliveryMethod: .poll,
                        eventsRequested: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .created)
                streamID = try res.content.decode(SSFStreamResponse.self).id
            }
            let id = try #require(streamID)

            let created = try await app.ssfStreamsPersistence.stream(id: id)
            let storedToken = try #require(created?.encryptedAuthToken)
            #expect(storedToken.hasPrefix(SecretsEncryptionService.encryptedPrefix))
            #expect(!storedToken.contains("management-secret-original"))
            let decrypted = try app.secretsEncryption.decrypt(storedToken)
            #expect(decrypted == "management-secret-original")

            // Rotating the token through the update path re-encrypts it.
            try await app.test(.PUT, "\(base)/\(id.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateSSFStreamRequest(
                        name: nil,
                        description: nil,
                        authToken: "rotated-token",
                        expectedIssuer: nil,
                        expectedAudience: nil,
                        eventsRequested: nil,
                        enabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let updated = try await app.ssfStreamsPersistence.stream(id: id)
            let rotatedStored = try #require(updated?.encryptedAuthToken)
            #expect(rotatedStored.hasPrefix(SecretsEncryptionService.encryptedPrefix))
            let rotatedDecrypted = try app.secretsEncryption.decrypt(rotatedStored)
            #expect(rotatedDecrypted == "rotated-token")
        }
    }

    @Test("Receiver construction decrypts the stored management auth token")
    func receiverDecryptsStoredAuthToken() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "ssfrecv", email: "recv@example.com")
            let org = try await builder.createOrganization(name: "Recv Org")

            let key = try SecretsEncryptionService.parseKey(String(repeating: "ab", count: 32))
            app.secretsEncryption = SecretsEncryptionService(key: key)

            let stream = try await app.ssfStreamsPersistence.create(
                SSFStreamWrite(
                    organizationID: org.id!,
                    name: "Encrypted",
                    transmitterURL: "https://idp.example.com",
                    encryptedAuthToken: try app.secretsEncryption.encrypt("management-secret"),
                    deliveryMethod: .poll,
                    createdByID: user.id!
                )
            )

            // With the key configured, building the receiver decrypts the token.
            _ = try await app.ssf.receiver(for: stream)

            // Without it, the encrypted token must fail loudly instead of being
            // sent to the transmitter as-is.
            await app.ssf.invalidateReceiver(for: stream.id)
            app.secretsEncryption = .disabled
            await #expect(throws: (any Error).self) {
                _ = try await app.ssf.receiver(for: stream)
            }
        }
    }

    @Test("Stream creation validates the transmitter URL")
    func createRejectsInvalidTransmitterURL() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "ssfadmin2", email: "a2@example.com")
            let org = try await builder.createOrganization(name: "URL Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            let token = try await user.generateAPIKey(on: app)

            // Malformed, plaintext, and non-allow-listed transmitter hosts are
            // all rejected: streams drive server-side HTTP requests (SSRF).
            for badURL in ["not a url", "http://idp.example.com", "https://169.254.169.254"] {
                try await app.test(.POST, "/api/organizations/\(org.id!.uuidString)/ssf-streams") {
                    req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        CreateSSFStreamRequest(
                            name: "bad",
                            description: nil,
                            transmitterURL: badURL,
                            authToken: nil,
                            expectedIssuer: nil,
                            expectedAudience: nil,
                            deliveryMethod: .poll,
                            eventsRequested: nil
                        ))
                } afterResponse: { res in
                    #expect(res.status == .unprocessableEntity, "expected 422 for \(badURL)")
                }
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
            let token = try await user.generateAPIKey(on: app)

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
                try await user.replacing(sessionEpoch: user.sessionEpoch + 1).save(on: app.db)
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

            try await user.replacing(sessionEpoch: 1).save(on: app.db)
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
            try await user.replacing(disabledAt: .some(Date())).save(on: app.db)

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
                try await user.replacing(sessionEpoch: 3).save(on: app.db)
                req.apiKey = try await app.apiKeysPersistence.issue(
                    APIKeyWrite(
                        userID: try user.requireID(),
                        name: "epoch-test",
                        keyHash: "epoch-test-hash",
                        keyPrefix: "sk_epoch...",
                        restriction: CredentialRestriction.unrestricted.stored
                    ),
                    maximumKeysPerUser: 10
                )
            }
            #expect(res.status == .ok)
        }
    }

    @Test("End to end: a delivered session-revoked SET locks out the session")
    func endToEndSessionRevocation() async throws {
        setenv("SSF_ALLOW_UNVERIFIED_TOKENS", "true", 1)
        setenv("SSF_TRANSMITTER_ALLOWED_SUFFIXES", ".example.com", 1)
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
            try await app.test(.POST, "/ssf/events/\(fixture.stream.id.uuidString)") { req in
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

// MARK: - Transmitter URL allow-list

/// The transmitter URL is org-admin supplied and drives server-side fetches
/// (discovery, stream management, polling) over the *shared* HTTP client, so
/// this allow-list is the only gate on that path — there is no address
/// classification or connection pin behind it, unlike the guarded fetches.
/// That makes the matching rule load-bearing, and it is exercised through the
/// list-taking overload so no process-wide environment is disturbed.
@Suite("SSF Transmitter URL Validation")
struct SSFTransmitterURLValidationTests {
    private func validate(_ url: String, suffixes: [String], hosts: Set<String> = []) throws {
        try SSFValidation.validateTransmitterURL(
            url, label: "transmitterURL", allowedHosts: hosts, allowedSuffixes: suffixes)
    }

    /// The trap: `SSF_TRANSMITTER_ALLOWED_SUFFIXES` defaults to the OIDC suffix
    /// list, so an operator who writes `example.com` there (or in
    /// `OIDC_DISCOVERY_ALLOWED_SUFFIXES`, which feeds this) must not thereby
    /// allow `evilexample.com` to receive stream-management calls.
    @Test("A dotless suffix entry does not match a lookalike domain")
    func dotlessSuffixMatchesOnLabelBoundary() throws {
        try validate("https://events.example.com/ssf", suffixes: ["example.com"])
        try validate("https://example.com/ssf", suffixes: ["example.com"])

        #expect(throws: (any Error).self) {
            try self.validate("https://evilexample.com/ssf", suffixes: ["example.com"])
        }
    }

    @Test("A leading-dot entry still matches subdomains only")
    func leadingDotSuffixMatchesSubdomains() throws {
        try validate("https://events.example.com/ssf", suffixes: [".example.com"])

        #expect(throws: (any Error).self) {
            try self.validate("https://evilexample.com/ssf", suffixes: [".example.com"])
        }
    }

    @Test("Plaintext and unlisted hosts are refused")
    func rejectsPlaintextAndUnlistedHosts() throws {
        #expect(throws: (any Error).self) {
            try self.validate("http://events.example.com/ssf", suffixes: ["example.com"])
        }
        #expect(throws: (any Error).self) {
            try self.validate("https://169.254.169.254/ssf", suffixes: ["example.com"])
        }
    }
}
