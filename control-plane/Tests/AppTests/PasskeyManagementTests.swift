import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// Self-service passkey management (`/api/users/me/passkeys`) and the profile
/// fields it sits next to.
@Suite("Passkey Management Tests", .serialized)
final class PasskeyManagementTests: BaseTestCase {

    // MARK: - Helpers

    /// Mint a browser session for `user` and return it as a cookie header
    /// value. Mirrors what `req.auth.login` + `stampSessionEpoch` write on a
    /// real passkey login, so session-only routes can be exercised without
    /// driving a WebAuthn ceremony.
    private func sessionCookie(for user: User, on app: Application) async throws -> HTTPCookies {
        var data = SessionData()
        data["_UserSession"] = try user.requireID().uuidString
        data[UserSecurityMiddleware.sessionEpochKey] = String(user.sessionEpoch)
        let sessionID = try await app.sessions.driver.createSession(
            data, for: Request(application: app, on: app.eventLoopGroup.any())
        ).get()
        var cookies = HTTPCookies()
        cookies["vapor-session"] = HTTPCookies.Value(string: sessionID.string)
        return cookies
    }

    @discardableResult
    private func makeCredential(
        for user: User,
        name: String? = nil,
        on db: Database
    ) async throws -> UserCredential {
        let credential = UserCredential(
            userID: try user.requireID(),
            credentialID: Data(UUID().uuidString.utf8),
            publicKey: Data("public-key".utf8),
            name: name
        )
        try await credential.save(on: db)
        return credential
    }

    private func makeUser(
        username: String,
        on db: Database
    ) async throws -> User {
        let user = User(
            username: username,
            email: "\(username)@example.com",
            displayName: username
        )
        try await user.save(on: db)
        return user
    }

    // MARK: - List

    @Test("list returns only the caller's passkeys")
    func testListScopedToCaller() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let other = try await makeUser(username: "other", on: app.db)
            try await makeCredential(for: testUser, name: "Mine", on: app.db)
            try await makeCredential(for: other, name: "Theirs", on: app.db)

            let cookies = try await sessionCookie(for: testUser, on: app)
            try await app.test(.GET, "/api/users/me/passkeys") { req in
                req.headers.cookie = cookies
            } afterResponse: { res in
                #expect(res.status == .ok)
                let passkeys = try res.content.decode([PasskeyResponse].self)
                #expect(passkeys.count == 1)
                #expect(passkeys.first?.name == "Mine")
            }
        }
    }

    @Test("list requires authentication")
    func testListUnauthenticated() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            try await app.test(.GET, "/api/users/me/passkeys") { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // MARK: - Rename

    @Test("rename updates the label")
    func testRename() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let credential = try await makeCredential(for: testUser, on: app.db)
            let cookies = try await sessionCookie(for: testUser, on: app)

            try await app.test(.PATCH, "/api/users/me/passkeys/\(credential.id!)") { req in
                req.headers.cookie = cookies
                try req.content.encode(RenamePasskeyRequest(name: "  Work laptop  "))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let passkey = try res.content.decode(PasskeyResponse.self)
                #expect(passkey.name == "Work laptop")
            }
        }
    }

    @Test("rename rejects an over-long name")
    func testRenameTooLong() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let credential = try await makeCredential(for: testUser, on: app.db)
            let cookies = try await sessionCookie(for: testUser, on: app)

            try await app.test(.PATCH, "/api/users/me/passkeys/\(credential.id!)") { req in
                req.headers.cookie = cookies
                try req.content.encode(RenamePasskeyRequest(name: String(repeating: "a", count: 65)))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("another user's passkey is not found")
    func testRenameOtherUsersPasskey() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let other = try await makeUser(username: "other", on: app.db)
            let credential = try await makeCredential(for: other, on: app.db)
            let cookies = try await sessionCookie(for: testUser, on: app)

            try await app.test(.PATCH, "/api/users/me/passkeys/\(credential.id!)") { req in
                req.headers.cookie = cookies
                try req.content.encode(RenamePasskeyRequest(name: "Stolen"))
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    // MARK: - Delete

    @Test("deleting the only passkey is refused")
    func testDeleteLastPasskeyRefused() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let credential = try await makeCredential(for: testUser, on: app.db)
            let cookies = try await sessionCookie(for: testUser, on: app)

            try await app.test(.DELETE, "/api/users/me/passkeys/\(credential.id!)") { req in
                req.headers.cookie = cookies
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            let remaining = try await UserCredential.query(on: app.db).count()
            #expect(remaining == 1)
        }
    }

    @Test("deleting a passkey succeeds while another remains")
    func testDeleteWithSpare() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let first = try await makeCredential(for: testUser, name: "First", on: app.db)
            try await makeCredential(for: testUser, name: "Second", on: app.db)
            let cookies = try await sessionCookie(for: testUser, on: app)

            try await app.test(.DELETE, "/api/users/me/passkeys/\(first.id!)") { req in
                req.headers.cookie = cookies
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let remaining = try await UserCredential.query(on: app.db).all()
            #expect(remaining.count == 1)
            #expect(remaining.first?.name == "Second")
        }
    }

    @Test("an OIDC-linked account may remove its last passkey")
    func testDeleteLastPasskeyAllowedForOIDCUser() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let provider = OIDCProvider(
                organizationID: try testOrganization.requireID(),
                name: "idp",
                clientID: "client",
                clientSecret: "secret",
                issuer: "https://idp.example.com"
            )
            try await provider.save(on: app.db)
            testUser.linkToOIDCProvider(try provider.requireID(), subject: "sub-1")
            try await testUser.save(on: app.db)

            let credential = try await makeCredential(for: testUser, on: app.db)
            let cookies = try await sessionCookie(for: testUser, on: app)

            try await app.test(.DELETE, "/api/users/me/passkeys/\(credential.id!)") { req in
                req.headers.cookie = cookies
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
        }
    }

    // MARK: - Credential type

    @Test("API keys cannot manage passkeys")
    func testAPIKeyCannotMutatePasskeys() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let first = try await makeCredential(for: testUser, on: app.db)
            try await makeCredential(for: testUser, on: app.db)

            try await app.test(.DELETE, "/api/users/me/passkeys/\(first.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            try await app.test(.POST, "/api/users/me/passkeys/begin") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Add ceremony

    @Test("begin issues a challenge in the add-passkey namespace")
    func testAddBeginStoresNamespacedChallenge() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let cookies = try await sessionCookie(for: testUser, on: app)

            try await app.test(.POST, "/api/users/me/passkeys/begin") { req in
                req.headers.cookie = cookies
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let challenges = try await AuthenticationChallenge.query(on: app.db).all()
            #expect(challenges.count == 1)
            #expect(challenges.first?.operation == PasskeyController.addChallengeOperation)
            #expect(challenges.first?.userID == testUser.id)
        }
    }

    @Test("begin is refused past the per-account passkey limit")
    func testAddBeginLimit() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            for index in 0..<PasskeyController.maxPasskeysPerUser {
                try await makeCredential(for: testUser, name: "key-\(index)", on: app.db)
            }
            let cookies = try await sessionCookie(for: testUser, on: app)

            try await app.test(.POST, "/api/users/me/passkeys/begin") { req in
                req.headers.cookie = cookies
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("a disabled account cannot start an add ceremony")
    func testAddBeginRejectsDisabledAccount() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            testUser.disabledAt = Date()
            try await testUser.save(on: app.db)
            let cookies = try await sessionCookie(for: testUser, on: app)

            try await app.test(.POST, "/api/users/me/passkeys/begin") { req in
                req.headers.cookie = cookies
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Profile fields

    @Test("a user can change their own username")
    func testUsernameUpdate() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            try await app.test(.PUT, "/api/users/\(testUser.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateUserRequest(username: "  new.name  ", displayName: "New Name"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let user = try res.content.decode(User.Public.self)
                #expect(user.username == "new.name")
                #expect(user.displayName == "New Name")
            }
        }
    }

    @Test("an invalid username is rejected")
    func testUsernameValidation() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            for invalid in ["ab", "has space", "with@sign", String(repeating: "x", count: 65)] {
                try await app.test(.PUT, "/api/users/\(testUser.id!)") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                    try req.content.encode(UpdateUserRequest(username: invalid))
                } afterResponse: { res in
                    #expect(res.status == .badRequest, "expected \(invalid) to be rejected")
                }
            }
        }
    }

    @Test("a taken username is rejected")
    func testUsernameConflict() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            _ = try await makeUser(username: "taken", on: app.db)

            try await app.test(.PUT, "/api/users/\(testUser.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(UpdateUserRequest(username: "taken"))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("an invalid email is rejected")
    func testEmailValidation() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            try await app.test(.PUT, "/api/users/\(testUser.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(UpdateUserRequest(email: "not-an-email"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("SCIM-provisioned accounts cannot be edited here")
    func testSCIMProvisionedUpdateForbidden() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            testUser.scimProvisioned = true
            try await testUser.save(on: app.db)

            try await app.test(.PUT, "/api/users/\(testUser.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(UpdateUserRequest(displayName: "Renamed"))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }
}
