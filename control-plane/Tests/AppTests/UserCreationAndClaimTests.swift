import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

@Suite("Admin user creation & passkey claim", .serialized)
final class UserCreationAndClaimTests: BaseTestCase {

    private func makeAdminToken(on db: Database) async throws -> String {
        let admin = User(
            username: "admin", email: "admin@example.com", displayName: "Admin", isSystemAdmin: true
        )
        try await admin.save(on: db)
        return try await admin.generateAPIKey(on: db)
    }

    // MARK: - create authorization

    @Test("create is forbidden for non-admins")
    func testCreateForbidden() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: "neo", email: "neo@example.com", displayName: "Neo",
                        isSystemAdmin: false))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            let created = try await User.query(on: app.db).filter(\.$username == "neo").first()
            #expect(created == nil)
        }
    }

    // MARK: - create behavior

    @Test("admin create makes a local user and a valid claim token")
    func testCreateSucceeds() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let adminToken = try await makeAdminToken(on: app.db)

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
            let claim = try #require(try await AccountClaimToken.findByToken(rawToken, on: app.db))
            #expect(claim.$user.id == createdUserID)
            #expect(claim.claimedAt == nil)
            #expect(claim.isValid)

            // The user exists with no credentials yet.
            let user = try #require(try await User.find(createdUserID, on: app.db))
            let credentialCount = try await user.$credentials.query(on: app.db).count()
            #expect(credentialCount == 0)
        }
    }

    @Test("admin create can grant system admin rights")
    func testCreateGrantsAdmin() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let adminToken = try await makeAdminToken(on: app.db)

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
            try await setupCommonTestData(on: app.db)
            let adminToken = try await makeAdminToken(on: app.db)

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

    // MARK: - claim info

    @Test("claim info reports a valid invite")
    func testClaimInfoValid() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let adminToken = try await makeAdminToken(on: app.db)

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
            try await setupCommonTestData(on: app.db)

            try await app.test(.GET, "/auth/claim/claim_does_not_exist") { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("an expired claim token is reported invalid and cannot begin a ceremony")
    func testExpiredClaimToken() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            let invitee = User(
                username: "invitee", email: "invitee@example.com", displayName: "Invitee")
            try await invitee.save(on: app.db)

            let raw = AccountClaimToken.generateToken()
            let token = AccountClaimToken(
                userID: try invitee.requireID(),
                tokenHash: AccountClaimToken.hashToken(raw),
                tokenPrefix: AccountClaimToken.extractPrefix(raw),
                expiresAt: Date().addingTimeInterval(-60),
                createdByID: nil)
            try await token.save(on: app.db)

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
            try await setupCommonTestData(on: app.db)
            let adminToken = try await makeAdminToken(on: app.db)

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

            try await app.test(.POST, "/auth/claim/begin") { req in
                try req.content.encode(ClaimBeginRequest(token: rawToken))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // The invite-authorized challenge must be namespaced so it cannot be
            // redeemed via the open /auth/register/finish path (which only
            // consumes "registration" challenges).
            let challenges = try await AuthenticationChallenge.query(on: app.db).all()
            #expect(challenges.contains { $0.operation == "claim" })
            #expect(challenges.allSatisfy { $0.operation != "registration" })
        }
    }

    // MARK: - invite accounts are gated to the claim flow

    @Test("invited accounts cannot be claimed via open self-registration")
    func testRegisterBeginBlockedForInvitedAccount() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let adminToken = try await makeAdminToken(on: app.db)

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
}
