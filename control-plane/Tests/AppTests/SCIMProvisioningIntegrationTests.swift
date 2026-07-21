import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

// MARK: - Fixtures

private struct SCIMProvisioningFixture {
    let organization: Organization
    let rawToken: String
}

/// An org plus an active SCIM provisioning token, the way the token-management
/// API would mint one (only the hash is stored; the raw value is what an IdP
/// sends as a bearer token).
private func makeSCIMFixture(
    _ app: Application, orgName: String = "SCIM Org", username: String = "scimadmin"
) async throws -> SCIMProvisioningFixture {
    let builder = TestDataBuilder(db: app.db)
    let user = try await builder.createUser(username: username, email: "\(username)@example.com")
    let org = try await builder.createOrganization(name: orgName)
    try await builder.addUserToOrganization(user: user, organization: org, role: "admin")

    let rawToken = SCIMToken.generateToken()
    let token = SCIMToken(
        organizationID: org.id!,
        name: "IdP provisioning",
        tokenHash: SCIMToken.hashToken(rawToken),
        tokenPrefix: SCIMToken.extractPrefix(rawToken),
        createdByID: user.id!
    )
    try await token.save(on: app.db)

    return SCIMProvisioningFixture(organization: org, rawToken: rawToken)
}

// MARK: - Middleware-stack integration tests

/// End-to-end requests against the SCIM data plane through the full middleware
/// stack (session authenticator, SpiceDBAuthMiddleware, …). IdP provisioning
/// requests carry only an org-scoped `scim_` bearer token — no user session —
/// so these tests pin the middleware exemption that lets them reach the
/// controller, where the token is actually verified.
@Suite("SCIM Provisioning Integration Tests", .serialized)
struct SCIMProvisioningIntegrationTests {

    /// Distinguishes a handler-level rejection (SCIM error document) from a
    /// SpiceDBAuthMiddleware rejection (Vapor's generic `{"error":true,…}`
    /// body synthesized from the thrown Abort).
    private let scimErrorSchema = "urn:ietf:params:scim:api:messages:2.0:Error"

    @Test("Valid scim_ token lists users through the full middleware stack")
    func validTokenListsUsers() async throws {
        try await withTestApp { app in
            let fixture = try await makeSCIMFixture(app)
            let orgID = fixture.organization.id!.uuidString

            try await app.test(.GET, "/organizations/\(orgID)/scim/v2/Users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.rawToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let contentType = res.headers.first(name: .contentType) ?? ""
                #expect(contentType.contains("application/scim+json"))
                let body = res.body.string
                #expect(body.contains("urn:ietf:params:scim:api:messages:2.0:ListResponse"))
            }
        }
    }

    @Test("Valid scim_ token provisions a user via POST /Users")
    func validTokenCreatesUser() async throws {
        try await withTestApp { app in
            let fixture = try await makeSCIMFixture(app)
            let orgID = fixture.organization.id!.uuidString

            let createBody = """
                {
                    "schemas": ["urn:ietf:params:scim:schemas:core:2.0:User"],
                    "userName": "provisioned.by.idp",
                    "displayName": "Provisioned User",
                    "emails": [{"value": "provisioned@example.com", "primary": true}],
                    "active": true
                }
                """

            try await app.test(.POST, "/organizations/\(orgID)/scim/v2/Users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.rawToken)
                req.headers.contentType = HTTPMediaType(type: "application", subType: "scim+json")
                req.body = ByteBufferAllocator().buffer(string: createBody)
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let created = try await User.query(on: app.db)
                .filter(\.$username == "provisioned.by.idp")
                .first()
            let createdUser = try #require(created)
            #expect(createdUser.scimProvisioned == true)

            let membership = try await UserOrganization.query(on: app.db)
                .filter(\.$user.$id == createdUser.id!)
                .filter(\.$organization.$id == fixture.organization.id!)
                .first()
            #expect(membership != nil)
        }
    }

    @Test("Missing bearer token is rejected by the SCIM handler, not the session middleware")
    func missingTokenRejectedByHandler() async throws {
        try await withTestApp { app in
            let fixture = try await makeSCIMFixture(app)
            let orgID = fixture.organization.id!.uuidString

            try await app.test(.GET, "/organizations/\(orgID)/scim/v2/Users") { _ in
            } afterResponse: { res in
                #expect(res.status == .unauthorized)
                let body = res.body.string
                #expect(body.contains(self.scimErrorSchema))
            }
        }
    }

    @Test("A scim_ token scoped to a different organization is rejected")
    func crossOrganizationTokenRejected() async throws {
        try await withTestApp { app in
            let orgA = try await makeSCIMFixture(app, orgName: "Org A", username: "scimadmina")
            let orgB = try await makeSCIMFixture(app, orgName: "Org B", username: "scimadminb")
            let orgAID = orgA.organization.id!.uuidString

            try await app.test(.GET, "/organizations/\(orgAID)/scim/v2/Users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: orgB.rawToken)
            } afterResponse: { res in
                #expect(res.status == .unauthorized)
                let body = res.body.string
                #expect(body.contains(self.scimErrorSchema))
            }
        }
    }

    @Test("A revoked scim_ token is rejected")
    func revokedTokenRejected() async throws {
        try await withTestApp { app in
            let fixture = try await makeSCIMFixture(app)
            let orgID = fixture.organization.id!.uuidString

            let token = try #require(
                try await SCIMToken.query(on: app.db)
                    .filter(\.$tokenHash == SCIMToken.hashToken(fixture.rawToken))
                    .first()
            )
            token.isActive = false
            try await token.save(on: app.db)

            try await app.test(.GET, "/organizations/\(orgID)/scim/v2/Users") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.rawToken)
            } afterResponse: { res in
                #expect(res.status == .unauthorized)
                let body = res.body.string
                #expect(body.contains(self.scimErrorSchema))
            }
        }
    }

    @Test("SCIM token management API is still session-guarded")
    func tokenManagementStillGuarded() async throws {
        try await withTestApp { app in
            let fixture = try await makeSCIMFixture(app)
            let orgID = fixture.organization.id!.uuidString

            // The carve-out is for /scim/v2/** only: the token-management API
            // under /settings/scim-tokens must still demand a user session.
            try await app.test(.GET, "/organizations/\(orgID)/settings/scim-tokens") { _ in
            } afterResponse: { res in
                #expect(res.status == .unauthorized)
                let body = res.body.string
                #expect(!body.contains(self.scimErrorSchema))
            }
        }
    }
}
