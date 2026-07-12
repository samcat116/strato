import Fluent
import SQLKit
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

    @Test("admin create can provision the invitee into an organization")
    func testCreateWithOrgAssignment() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let adminToken = try await makeAdminToken(on: app.db)
            let orgID = try testOrganization.requireID()

            var createdUserID: UUID?
            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: "neo", email: "neo@example.com", displayName: "Neo",
                        isSystemAdmin: false, organizationId: orgID, role: "admin"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let body = try res.content.decode(AdminCreateUserResponse.self)
                #expect(body.user.currentOrganizationId == orgID)
                createdUserID = body.user.id
            }

            let membership = try await UserOrganization.query(on: app.db)
                .filter(\.$user.$id == #require(createdUserID))
                .filter(\.$organization.$id == orgID)
                .first()
            #expect(membership?.role == "admin")
        }
    }

    @Test("admin create rejects an unknown assigned organization")
    func testCreateWithUnknownOrg() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let adminToken = try await makeAdminToken(on: app.db)

            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: "neo", email: "neo@example.com", displayName: "Neo",
                        isSystemAdmin: false, organizationId: UUID(), role: "member"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // The whole create rolls back — no orphaned user.
            let created = try await User.query(on: app.db).filter(\.$username == "neo").first()
            #expect(created == nil)
        }
    }

    @Test("assigned-org create rolls back when the SpiceDB tuple write fails")
    func testCreateOrgAssignmentRollsBackOnSpiceDBFailure() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let adminToken = try await makeAdminToken(on: app.db)
            let orgID = try testOrganization.requireID()

            // Force the mirrored org-role write to fail.
            app.spicedbMockWritesFail = true

            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: "neo", email: "neo@example.com", displayName: "Neo",
                        isSystemAdmin: false, organizationId: orgID, role: "member"))
            } afterResponse: { res in
                #expect(res.status != .ok)
            }

            // The whole create is rolled back — no orphaned user or claim token.
            let user = try await User.query(on: app.db).filter(\.$username == "neo").first()
            #expect(user == nil)
        }
    }

    @Test("org list-all is system-admin only and includes non-member orgs")
    func testListAllOrganizations() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)
            let adminToken = try await makeAdminToken(on: app.db)

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
            try await setupCommonTestData(on: app.db)
            let adminToken = try await makeAdminToken(on: app.db)
            let orgID = try testOrganization.requireID()

            try await app.test(.POST, "/api/users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    AdminCreateUserRequest(
                        username: "neo", email: "neo@example.com", displayName: "Neo",
                        isSystemAdmin: false, organizationId: orgID, role: "superuser"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
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

    @Test("claim-token consume is atomic and one-time")
    func testClaimTokenConsumeIsOneTime() async throws {
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
                expiresAt: Date().addingTimeInterval(3600),
                createdByID: nil)
            try await token.save(on: app.db)

            // This is the exact conditional consume claimFinish runs before
            // enrolling a credential: only the first attempt claims the token.
            let sql = try #require(app.db as? SQLDatabase)
            let claimID = try token.requireID()
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
