import Fluent
import SQLKit
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

@Suite("Admin user creation & passkey claim", .serialized)
final class UserCreationAndClaimTests: BaseTestCase {

    private func makeAdminToken(on app: Application) async throws -> String {
        let admin = User(
            username: "admin", email: "admin@example.com", displayName: "Admin", isSystemAdmin: true
        )
        try await admin.save(on: app.db)
        return try await admin.generateAPIKey(on: app)
    }

    // MARK: - create authorization

    @Test("create is forbidden for non-admins")
    func testCreateForbidden() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)

            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: "neo", email: "neo@example.com", displayName: "Neo",
                        isSystemAdmin: false))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            let created = try await LegacyUserStore.users(username: "neo", on: app.db).first
            #expect(created == nil)
        }
    }

    // MARK: - create behavior

    @Test("admin create makes a local user and a valid claim token")
    func testCreateSucceeds() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)
            let adminToken = try await makeAdminToken(on: app)

            var createdUserID: UUID?
            var rawToken = ""

            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: "neo", email: "neo@example.com", displayName: "Neo",
                        isSystemAdmin: false))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(AdminCreateUserResponse.self)
                #expect(body.user.source == .local)
                #expect(body.user.username == "neo")
                #expect(body.user.isSystemAdmin == false)
                #expect(!body.claimToken.isEmpty)
                #expect(body.claimUrl.contains("/claim?token="))
                createdUserID = body.user.id
                rawToken = body.claimToken
            }

            // The raw token is not stored; only its hash, resolvable back to the user.
            let claim = try #require(try await findTestAccountClaim(rawToken: rawToken, on: app))
            #expect(claim.userID == createdUserID)
            #expect(claim.claimedAt == nil)
            #expect(claim.isValid())

            // The user exists with no credentials yet.
            let user = try #require(try await User.find(createdUserID, on: app.db))
            let credentialCount = try await app.passkeysPersistence.credentials(
                userID: user.requireID()
            ).count
            #expect(credentialCount == 0)
        }
    }

    @Test("admin create can grant system admin rights")
    func testCreateGrantsAdmin() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)
            let adminToken = try await makeAdminToken(on: app)

            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: "root", email: "root@example.com", displayName: "Root",
                        isSystemAdmin: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(AdminCreateUserResponse.self)
                #expect(body.user.isSystemAdmin == true)
            }
        }
    }

    @Test("admin create rejects a duplicate username or email")
    func testCreateConflict() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)
            let adminToken = try await makeAdminToken(on: app)

            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: testUser.username, email: "different@example.com",
                        displayName: "Dupe", isSystemAdmin: false))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("admin create can provision the invitee into an organization")
    func testCreateWithOrgAssignment() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)
            let adminToken = try await makeAdminToken(on: app)
            let orgID = try testOrganization.requireID()

            var createdUserID: UUID?
            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: "neo", email: "neo@example.com", displayName: "Neo",
                        isSystemAdmin: false, organizationId: orgID, role: IAMRole.admin.seededID))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(AdminCreateUserResponse.self)
                #expect(body.user.currentOrganizationId == orgID)
                createdUserID = body.user.id
            }

            let membership = try await OrganizationMembershipStore.membership(
                userID: #require(createdUserID), organizationID: orgID, on: app.db)
            #expect(membership?.roleID == IAMRole.admin.seededID)
        }
    }

    @Test("admin create rejects an unknown assigned organization")
    func testCreateWithUnknownOrg() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)
            let adminToken = try await makeAdminToken(on: app)

            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: "neo", email: "neo@example.com", displayName: "Neo",
                        isSystemAdmin: false, organizationId: UUID(), role: nil))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // The whole create rolls back — no orphaned user.
            let created = try await LegacyUserStore.users(username: "neo", on: app.db).first
            #expect(created == nil)
        }
    }

    @Test("org list-all is system-admin only and includes non-member orgs")
    func testListAllOrganizations() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)
            let adminToken = try await makeAdminToken(on: app)

            // An org the admin is not a member of.
            let other = Organization(name: "Zeta Corp", description: "")
            try await other.save(on: app.db)

            try await app.test(.GET, "/api/organizations/all") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            try await app.test(.GET, "/api/organizations/all") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let orgs = try res.content.decode([OrganizationResponse].self)
                #expect(orgs.contains { $0.name == "Zeta Corp" })
                #expect(orgs.contains { $0.id == testOrganization.id })
            }
        }
    }

    @Test("admin create rejects an invalid org role")
    func testCreateWithInvalidRole() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)
            let adminToken = try await makeAdminToken(on: app)
            let orgID = try testOrganization.requireID()

            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: "neo", email: "neo@example.com", displayName: "Neo",
                        isSystemAdmin: false, organizationId: orgID, role: UUID()))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - claim info

    @Test("claim info reports a valid invite")
    func testClaimInfoValid() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)
            let adminToken = try await makeAdminToken(on: app)

            var rawToken = ""
            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: "neo", email: "neo@example.com", displayName: "Neo",
                        isSystemAdmin: false))
            } afterResponse: { res in
                rawToken = try res.content.decode(AdminCreateUserResponse.self).claimToken
            }

            try await app.test(.GET, "/auth/claim/\(rawToken)") { res in
                #expect(res.status == .ok)
                let info = try res.content.decode(ClaimInfoResponse.self)
                #expect(info.username == "neo")
                #expect(info.displayName == "Neo")
                #expect(info.valid)
                #expect(info.alreadyClaimed == false)
                #expect(info.expired == false)
            }
        }
    }

    @Test("claim info 404s for an unknown token")
    func testClaimInfoUnknown() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)

            try await app.test(.GET, "/auth/claim/claim_does_not_exist") { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("an expired claim token is reported invalid and cannot begin a ceremony")
    func testExpiredClaimToken() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)

            let invitee = User(
                username: "invitee", email: "invitee@example.com", displayName: "Invitee")
            try await invitee.save(on: app.db)

            let token = try await seedTestAccountClaim(
                userID: try invitee.requireID(),
                expiresAt: Date().addingTimeInterval(-60),
                on: app
            )
            let raw = token.rawToken

            try await app.test(.GET, "/auth/claim/\(raw)") { res in
                #expect(res.status == .ok)
                let info = try res.content.decode(ClaimInfoResponse.self)
                #expect(info.valid == false)
                #expect(info.expired == true)
            }

            try await app.test(.POST, "/auth/claim/begin") { req in
                try req.content.encode(ClaimBeginRequest(token: raw))
            } afterResponse: { res in
                #expect(res.status == .gone)
            }
        }
    }

    @Test("claim begin stores its challenge under a claim-only operation")
    func testClaimBeginNamespacesChallenge() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)
            let adminToken = try await makeAdminToken(on: app)

            var rawToken = ""
            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: "neo", email: "neo@example.com", displayName: "Neo",
                        isSystemAdmin: false))
            } afterResponse: { res in
                rawToken = try res.content.decode(AdminCreateUserResponse.self).claimToken
            }

            var challenge = ""
            try await app.test(.POST, "/auth/claim/begin") { req in
                try req.content.encode(ClaimBeginRequest(token: rawToken))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let root = try #require(
                    JSONSerialization.jsonObject(with: Data(res.body.string.utf8))
                        as? [String: Any]
                )
                let options = try #require(root["options"] as? [String: Any])
                challenge = try #require(options["challenge"] as? String)
            }

            // The invite-authorized challenge must be namespaced so it cannot be
            // redeemed via the open /auth/register/finish path (which only
            // consumes "registration" challenges).
            #expect(
                try await app.passkeysPersistence.challenge(
                    challenge,
                    operation: "claim"
                ) != nil
            )
            #expect(
                try await app.passkeysPersistence.challenge(
                    challenge,
                    operation: "registration"
                ) == nil
            )
        }
    }

    @Test("claim-token consume is atomic and one-time")
    func testClaimTokenConsumeIsOneTime() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)

            let invitee = User(
                username: "invitee", email: "invitee@example.com", displayName: "Invitee")
            try await invitee.save(on: app.db)

            let token = try await seedTestAccountClaim(
                userID: try invitee.requireID(),
                expiresAt: Date().addingTimeInterval(3600),
                on: app
            )

            // This is the exact conditional consume claimFinish runs before
            // enrolling a credential: only the first attempt claims the token.
            let sql = try #require(app.db as? SQLDatabase)
            let claimID = token.id
            let first = try await sql.raw(
                """
                UPDATE account_claim_tokens SET claimed_at = \(bind: Date())
                WHERE id = \(bind: claimID) AND claimed_at IS NULL
                RETURNING id
                """
            ).all()
            let second = try await sql.raw(
                """
                UPDATE account_claim_tokens SET claimed_at = \(bind: Date())
                WHERE id = \(bind: claimID) AND claimed_at IS NULL
                RETURNING id
                """
            ).all()

            #expect(first.count == 1)
            #expect(second.isEmpty)
        }
    }

    // MARK: - invite accounts are gated to the claim flow

    @Test("invited accounts cannot be claimed via open self-registration")
    func testRegisterBeginBlockedForInvitedAccount() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)
            let adminToken = try await makeAdminToken(on: app)

            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: "neo", email: "neo@example.com", displayName: "Neo",
                        isSystemAdmin: false))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // The open self-registration begin endpoint must refuse to attach a
            // passkey to an account that has an outstanding claim invite.
            try await app.test(.POST, "/auth/register/begin") { req in
                try req.content.encode(RegistrationBeginRequest(username: "neo"))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    /// A *spent* invite must stop blocking enrollment (STR-178).
    ///
    /// `claimFinish` stamps `claimedAt` rather than deleting the row, so a gate
    /// counting every token would bar an invited user from ever adding a second
    /// passkey — permanently, since `/auth/register/begin` is the only
    /// enrollment endpoint. That mattered little while invites were rare; once
    /// `App bootstrap --admin-email` issues one, it would cap the deployment's
    /// administrator at a single authenticator.
    ///
    /// Both halves run against a self-registered account carrying the browser
    /// session that created it, because that is the one caller the gate under
    /// test is reachable from: the session check above it admits only the
    /// account's owner or its pending-enrollment session.
    @Test("a claimed invite no longer blocks passkey enrollment")
    func testRegisterBeginAllowedAfterInviteClaimed() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)

            var sessionCookie: String?
            try await app.test(.POST, "/api/users/register") { req in
                try req.content.encode(
                    CreateUserRequest(username: "trinity", email: "trinity@example.com", displayName: "Trinity"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                sessionCookie = res.headers.setCookie?["vapor-session"]?.string
            }
            let cookie = try #require(sessionCookie)
            let user = try #require(try await LegacyUserStore.users(username: "trinity", on: app.db).first)

            func beginRegistration() async throws -> HTTPStatus {
                var status: HTTPStatus = .internalServerError
                var cookies = HTTPCookies()
                cookies["vapor-session"] = HTTPCookies.Value(string: cookie)
                try await app.test(.POST, "/auth/register/begin") { req in
                    req.headers.cookie = cookies
                    try req.content.encode(RegistrationBeginRequest(username: "trinity"))
                } afterResponse: { res in
                    status = res.status
                }
                return status
            }

            // An outstanding invite blocks, as above.
            let invite = try await seedTestAccountClaim(
                userID: try user.requireID(),
                rawToken: "claim_pending",
                expiresAt: Date().addingTimeInterval(3600),
                on: app
            )
            #expect(try await beginRegistration() == .forbidden)

            // Spending it releases the gate.
            try await consumeTestAccountClaim(id: invite.id, on: app)
            #expect(try await beginRegistration() == .ok)
        }
    }
}
