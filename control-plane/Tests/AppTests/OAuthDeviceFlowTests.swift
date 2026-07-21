import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

@Suite("OAuth Device Flow Tests", .serialized)
struct OAuthDeviceFlowTests {

    // MARK: - Helpers

    func createTestUser(on db: Database, username: String = "clitester") async throws -> User {
        let user = User(
            username: username,
            email: "\(username)@example.com",
            displayName: "CLI Tester",
            isSystemAdmin: false
        )
        try await user.save(on: db)
        return user
    }

    struct TokenForm: Content {
        let grantType: String
        let deviceCode: String?
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case grantType = "grant_type"
            case deviceCode = "device_code"
            case refreshToken = "refresh_token"
        }
    }

    func startDeviceFlow(
        _ app: Application, scope: String? = nil, clientName: String? = "test-cli"
    ) async throws -> DeviceAuthorizationResponse {
        var response: DeviceAuthorizationResponse?
        try await app.test(
            .POST, "/oauth/device_authorization",
            beforeRequest: { req in
                try req.content.encode(
                    OAuthController.DeviceAuthorizationRequest(clientName: clientName, scope: scope),
                    as: .urlEncodedForm
                )
            }
        ) { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(DeviceAuthorizationResponse.self)
        }
        return try #require(response)
    }

    /// Clears the poll-interval gate so consecutive polls in one test don't
    /// trip slow_down.
    func resetPollTimer(deviceCode: String, on db: Database) async throws {
        let authorization = try #require(try await DeviceAuthorization.findByDeviceCode(deviceCode, on: db))
        authorization.lastPolledAt = Date().addingTimeInterval(-60)
        try await authorization.save(on: db)
    }

    func pollToken(_ app: Application, deviceCode: String) async throws -> (HTTPStatus, TokenResponse?, String?) {
        var status: HTTPStatus = .internalServerError
        var token: TokenResponse?
        var errorCode: String?
        try await app.test(
            .POST, "/oauth/token",
            beforeRequest: { req in
                try req.content.encode(
                    TokenForm(
                        grantType: OAuthController.deviceCodeGrantType,
                        deviceCode: deviceCode,
                        refreshToken: nil
                    ),
                    as: .urlEncodedForm
                )
            }
        ) { res async in
            status = res.status
            token = try? res.content.decode(TokenResponse.self)
            errorCode = (try? res.content.decode(OAuthErrorResponse.self))?.error
        }
        return (status, token, errorCode)
    }

    func refreshToken(_ app: Application, refreshToken: String) async throws -> (HTTPStatus, TokenResponse?, String?) {
        var status: HTTPStatus = .internalServerError
        var token: TokenResponse?
        var errorCode: String?
        try await app.test(
            .POST, "/oauth/token",
            beforeRequest: { req in
                try req.content.encode(
                    TokenForm(grantType: "refresh_token", deviceCode: nil, refreshToken: refreshToken),
                    as: .urlEncodedForm
                )
            }
        ) { res async in
            status = res.status
            token = try? res.content.decode(TokenResponse.self)
            errorCode = (try? res.content.decode(OAuthErrorResponse.self))?.error
        }
        return (status, token, errorCode)
    }

    func approve(_ app: Application, userCode: String, apiKey: String) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.test(
            .POST, "/api/oauth/device/\(userCode)/approve",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            }
        ) { res async in
            status = res.status
        }
        return status
    }

    // MARK: - Code generation

    @Test("User codes use the RFC 8628 charset in XXXX-XXXX shape")
    func testUserCodeFormat() {
        for _ in 0..<20 {
            let code = DeviceAuthorization.generateUserCode()
            #expect(code.count == 9)
            let groups = code.split(separator: "-")
            #expect(groups.count == 2)
            for character in groups.joined() {
                #expect(DeviceAuthorization.userCodeCharset.contains(character))
            }
        }
    }

    @Test("User code normalization accepts sloppy input")
    func testUserCodeNormalization() {
        #expect(DeviceAuthorization.normalizeUserCode("bcdf-ghjk") == "BCDF-GHJK")
        #expect(DeviceAuthorization.normalizeUserCode("BCDFGHJK") == "BCDF-GHJK")
        #expect(DeviceAuthorization.normalizeUserCode("bcdf ghjk") == "BCDF-GHJK")
        #expect(DeviceAuthorization.normalizeUserCode("BCDF-GHJK") == "BCDF-GHJK")
    }

    // MARK: - Device flow

    @Test("Happy path: authorize, approve, redeem, authenticate")
    func testDeviceFlowHappyPath() async throws {
        try await withTestApp { app in
            let user = try await createTestUser(on: app.db)
            let apiKey = try await user.generateAPIKey(on: app.db)

            let start = try await startDeviceFlow(app)
            #expect(start.verificationUri.hasSuffix("/activate"))
            #expect(start.verificationUriComplete.contains(start.userCode))
            #expect(start.interval == 5)

            // Poll before approval: authorization_pending.
            let (pendingStatus, _, pendingError) = try await pollToken(app, deviceCode: start.deviceCode)
            #expect(pendingStatus == .badRequest)
            #expect(pendingError == "authorization_pending")

            // The approval page can look up the pending request.
            try await app.test(
                .GET, "/api/oauth/device/\(start.userCode)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let pending = try res.content.decode(PendingDeviceAuthorizationResponse.self)
                #expect(pending.clientName == "test-cli")
                #expect(pending.scopes == ["read", "write"])
            }

            #expect(try await approve(app, userCode: start.userCode, apiKey: apiKey) == .ok)

            try await resetPollTimer(deviceCode: start.deviceCode, on: app.db)
            let (status, token, _) = try await pollToken(app, deviceCode: start.deviceCode)
            #expect(status == .ok)
            let issued = try #require(token)
            #expect(issued.accessToken.hasPrefix("st_"))
            #expect(issued.refreshToken.hasPrefix("rt_"))
            #expect(issued.tokenType == "Bearer")
            #expect(issued.scope == "read write")

            // The access token authenticates against the real API surface.
            try await app.test(
                .GET, "/api/oauth/sessions",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: issued.accessToken)
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let sessions = try res.content.decode([CLISessionResponse].self)
                #expect(sessions.count == 1)
                #expect(sessions.first?.clientName == "test-cli")
            }

            // A device code is single-redemption.
            try await resetPollTimer(deviceCode: start.deviceCode, on: app.db)
            let (replayStatus, _, replayError) = try await pollToken(app, deviceCode: start.deviceCode)
            #expect(replayStatus == .badRequest)
            #expect(replayError == "invalid_grant")
        }
    }

    @Test("Polling faster than the interval returns slow_down")
    func testSlowDown() async throws {
        try await withTestApp { app in
            let start = try await startDeviceFlow(app)

            let (first, _, firstError) = try await pollToken(app, deviceCode: start.deviceCode)
            #expect(first == .badRequest)
            #expect(firstError == "authorization_pending")

            let (second, _, secondError) = try await pollToken(app, deviceCode: start.deviceCode)
            #expect(second == .badRequest)
            #expect(secondError == "slow_down")
        }
    }

    @Test("Expired device codes return expired_token")
    func testExpiredDeviceCode() async throws {
        try await withTestApp { app in
            let start = try await startDeviceFlow(app)

            let authorization = try #require(
                try await DeviceAuthorization.findByDeviceCode(start.deviceCode, on: app.db))
            authorization.expiresAt = Date().addingTimeInterval(-60)
            try await authorization.save(on: app.db)

            let (status, _, errorCode) = try await pollToken(app, deviceCode: start.deviceCode)
            #expect(status == .badRequest)
            #expect(errorCode == "expired_token")
        }
    }

    @Test("Denied requests return access_denied and disappear from lookup")
    func testDeniedDeviceCode() async throws {
        try await withTestApp { app in
            let user = try await createTestUser(on: app.db)
            let apiKey = try await user.generateAPIKey(on: app.db)
            let start = try await startDeviceFlow(app)

            try await app.test(
                .POST, "/api/oauth/device/\(start.userCode)/deny",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
                }
            ) { res async in
                #expect(res.status == .ok)
            }

            let (status, _, errorCode) = try await pollToken(app, deviceCode: start.deviceCode)
            #expect(status == .badRequest)
            #expect(errorCode == "access_denied")

            // No longer resolvable by the approval page.
            try await app.test(
                .GET, "/api/oauth/device/\(start.userCode)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
                }
            ) { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Unknown device codes return invalid_grant")
    func testUnknownDeviceCode() async throws {
        try await withTestApp { app in
            let (status, _, errorCode) = try await pollToken(app, deviceCode: "dc_bogus")
            #expect(status == .badRequest)
            #expect(errorCode == "invalid_grant")
        }
    }

    @Test("Approval accepts sloppy user-code input")
    func testApprovalNormalizesUserCode() async throws {
        try await withTestApp { app in
            let user = try await createTestUser(on: app.db)
            let apiKey = try await user.generateAPIKey(on: app.db)
            let start = try await startDeviceFlow(app)

            let sloppy = start.userCode.replacingOccurrences(of: "-", with: "").lowercased()
            #expect(try await approve(app, userCode: sloppy, apiKey: apiKey) == .ok)
        }
    }

    @Test("Invalid scopes are rejected at authorization time")
    func testInvalidScope() async throws {
        try await withTestApp { app in
            try await app.test(
                .POST, "/oauth/device_authorization",
                beforeRequest: { req in
                    try req.content.encode(
                        OAuthController.DeviceAuthorizationRequest(clientName: "x", scope: "read superuser"),
                        as: .urlEncodedForm
                    )
                }
            ) { res async in
                #expect(res.status == .badRequest)
                let error = try? res.content.decode(OAuthErrorResponse.self)
                #expect(error?.error == "invalid_scope")
            }
        }
    }

    // MARK: - Refresh rotation

    @Test("Refresh rotates both tokens; replaying an old refresh revokes the session")
    func testRefreshRotationAndReplayDetection() async throws {
        try await withTestApp { app in
            let user = try await createTestUser(on: app.db)
            let apiKey = try await user.generateAPIKey(on: app.db)
            let start = try await startDeviceFlow(app)
            _ = try await approve(app, userCode: start.userCode, apiKey: apiKey)
            try await resetPollTimer(deviceCode: start.deviceCode, on: app.db)
            let (_, firstToken, _) = try await pollToken(app, deviceCode: start.deviceCode)
            let first = try #require(firstToken)

            let (refreshStatus, secondToken, _) = try await refreshToken(app, refreshToken: first.refreshToken)
            #expect(refreshStatus == .ok)
            let second = try #require(secondToken)
            #expect(second.accessToken != first.accessToken)
            #expect(second.refreshToken != first.refreshToken)

            // The rotated-out access token no longer authenticates.
            try await app.test(
                .GET, "/api/oauth/sessions",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: first.accessToken)
                }
            ) { res async in
                #expect(res.status == .unauthorized)
            }

            // Replaying the pre-rotation refresh token kills the session.
            let (replayStatus, _, replayError) = try await refreshToken(app, refreshToken: first.refreshToken)
            #expect(replayStatus == .badRequest)
            #expect(replayError == "invalid_grant")

            let (postReplayStatus, _, postReplayError) = try await refreshToken(
                app, refreshToken: second.refreshToken)
            #expect(postReplayStatus == .badRequest)
            #expect(postReplayError == "invalid_grant")

            try await app.test(
                .GET, "/api/oauth/sessions",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: second.accessToken)
                }
            ) { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // MARK: - Revocation

    @Test("POST /oauth/revoke invalidates the session by either token")
    func testRevokeEndpoint() async throws {
        try await withTestApp { app in
            let user = try await createTestUser(on: app.db)
            let apiKey = try await user.generateAPIKey(on: app.db)
            let start = try await startDeviceFlow(app)
            _ = try await approve(app, userCode: start.userCode, apiKey: apiKey)
            try await resetPollTimer(deviceCode: start.deviceCode, on: app.db)
            let (_, issuedToken, _) = try await pollToken(app, deviceCode: start.deviceCode)
            let issued = try #require(issuedToken)

            try await app.test(
                .POST, "/oauth/revoke",
                beforeRequest: { req in
                    try req.content.encode(
                        OAuthController.RevokeRequest(token: issued.accessToken), as: .urlEncodedForm)
                }
            ) { res async in
                #expect(res.status == .ok)
            }

            try await app.test(
                .GET, "/api/oauth/sessions",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: issued.accessToken)
                }
            ) { res async in
                #expect(res.status == .unauthorized)
            }

            let (refreshStatus, _, _) = try await refreshToken(app, refreshToken: issued.refreshToken)
            #expect(refreshStatus == .badRequest)

            // Unknown tokens still get 200 (no token probing).
            try await app.test(
                .POST, "/oauth/revoke",
                beforeRequest: { req in
                    try req.content.encode(
                        OAuthController.RevokeRequest(token: "st_who_knows"), as: .urlEncodedForm)
                }
            ) { res async in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("Settings can list and revoke CLI sessions, scoped to the owner")
    func testSessionManagement() async throws {
        try await withTestApp { app in
            let user = try await createTestUser(on: app.db)
            let apiKey = try await user.generateAPIKey(on: app.db)
            let other = try await createTestUser(on: app.db, username: "someoneelse")
            let otherKey = try await other.generateAPIKey(on: app.db)

            let start = try await startDeviceFlow(app)
            _ = try await approve(app, userCode: start.userCode, apiKey: apiKey)
            try await resetPollTimer(deviceCode: start.deviceCode, on: app.db)
            let (_, issuedToken, _) = try await pollToken(app, deviceCode: start.deviceCode)
            let issued = try #require(issuedToken)

            // The other user sees no sessions and cannot revoke this one.
            var sessionID: UUID?
            try await app.test(
                .GET, "/api/oauth/sessions",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
                }
            ) { res async throws in
                let sessions = try res.content.decode([CLISessionResponse].self)
                sessionID = sessions.first?.id
            }
            let id = try #require(sessionID)

            try await app.test(
                .GET, "/api/oauth/sessions",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: otherKey)
                }
            ) { res async throws in
                let sessions = try res.content.decode([CLISessionResponse].self)
                #expect(sessions.isEmpty)
            }

            try await app.test(
                .DELETE, "/api/oauth/sessions/\(id)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: otherKey)
                }
            ) { res async in
                #expect(res.status == .notFound)
            }

            try await app.test(
                .DELETE, "/api/oauth/sessions/\(id)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
                }
            ) { res async in
                #expect(res.status == .noContent)
            }

            try await app.test(
                .GET, "/api/oauth/sessions",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: issued.accessToken)
                }
            ) { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // MARK: - Scope enforcement

    @Test("Read-scoped CLI tokens are forbidden from writes")
    func testCLITokenScopeEnforcement() async throws {
        try await withTestApp { app in
            let user = try await createTestUser(on: app.db)
            let apiKey = try await user.generateAPIKey(on: app.db)
            let start = try await startDeviceFlow(app, scope: "read")
            _ = try await approve(app, userCode: start.userCode, apiKey: apiKey)
            try await resetPollTimer(deviceCode: start.deviceCode, on: app.db)
            let (_, issuedToken, _) = try await pollToken(app, deviceCode: start.deviceCode)
            let issued = try #require(issuedToken)

            app.routes.all.removeAll()
            let protected = app.grouped(
                BearerAuthorizationHeaderAuthenticator(),
                APIKeyScopeMiddleware()
            )
            protected.get("resource") { _ in "read-ok" }
            protected.post("resource") { _ in "write-ok" }

            try await app.test(
                .GET, "/resource",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: issued.accessToken)
                }
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "read-ok")
            }

            try await app.test(
                .POST, "/resource",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: issued.accessToken)
                }
            ) { res async in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Route gating

    @Test("Public /oauth/ routes need no session; /api/oauth/ routes do")
    func testRouteGating() async throws {
        try await withTestApp { app in
            // Reachable without any credentials.
            _ = try await startDeviceFlow(app)

            try await app.test(.GET, "/api/oauth/sessions") { res async in
                #expect(res.status == .unauthorized)
            }
            try await app.test(.GET, "/api/oauth/device/BCDF-GHJK") { res async in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // MARK: - Expired access tokens

    @Test("Expired access tokens stop authenticating but refresh still works")
    func testExpiredAccessToken() async throws {
        try await withTestApp { app in
            let user = try await createTestUser(on: app.db)
            let apiKey = try await user.generateAPIKey(on: app.db)
            let start = try await startDeviceFlow(app)
            _ = try await approve(app, userCode: start.userCode, apiKey: apiKey)
            try await resetPollTimer(deviceCode: start.deviceCode, on: app.db)
            let (_, issuedToken, _) = try await pollToken(app, deviceCode: start.deviceCode)
            let issued = try #require(issuedToken)

            let session = try #require(
                try await CLISession.query(on: app.db)
                    .filter(\.$accessTokenHash == CLISession.hashToken(issued.accessToken))
                    .first())
            session.accessTokenExpiresAt = Date().addingTimeInterval(-60)
            try await session.save(on: app.db)

            try await app.test(
                .GET, "/api/oauth/sessions",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: issued.accessToken)
                }
            ) { res async in
                #expect(res.status == .unauthorized)
            }

            let (refreshStatus, refreshed, _) = try await refreshToken(app, refreshToken: issued.refreshToken)
            #expect(refreshStatus == .ok)
            #expect(refreshed != nil)
        }
    }
}
