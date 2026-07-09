import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// Centralized audit logging (issue #39): the middleware that records API
/// mutations and admin-bypassed requests, the explicit auth events, and the
/// query API that reads the trail back.
@Suite("Audit Logging Tests", .serialized)
final class AuditLoggingTests {

    private func withApp(
        systemAdmin: Bool = false,
        _ test: (Application, User, Organization, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "audituser",
                email: "audit@example.com",
                displayName: "Audit User",
                isSystemAdmin: systemAdmin
            )
            let org = try await builder.createOrganization(name: "Audit Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let token = try await user.generateAPIKey(on: app.db)
            try await test(app, user, org, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func events(
        ofType type: String, on db: any Database
    ) async throws -> [AuditEvent] {
        try await AuditEvent.query(on: db).filter(\.$eventType == type).all()
    }

    // MARK: - Middleware: API requests

    @Test("API mutation is audited with actor, resource, and status")
    func apiMutationIsAudited() async throws {
        try await withApp { app, user, org, token in
            try await app.test(.POST, "/api/api-keys") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["name": "audit-test-key"])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let recorded = try await self.events(ofType: "api.request", on: app.db)
            #expect(recorded.count == 1)
            let event = try #require(recorded.first)
            #expect(event.userID == user.id)
            #expect(event.username == "audituser")
            #expect(event.organizationID == org.id)
            #expect(event.method == "POST")
            #expect(event.path == "/api/api-keys")
            #expect(event.status == 200)
            #expect(event.resourceType == "api-keys")
            #expect(event.action == "create")
            #expect(event.adminBypass == false)
            #expect(event.apiKeyID != nil)
        }
    }

    @Test("Reads are not audited by default")
    func readsNotAuditedByDefault() async throws {
        try await withApp { app, _, _, token in
            try await app.test(.GET, "/api/api-keys") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let recorded = try await self.events(ofType: "api.request", on: app.db)
            #expect(recorded.isEmpty)
        }
    }

    @Test("System-admin bypassed requests are audited, including reads")
    func adminBypassIsAudited() async throws {
        try await withApp(systemAdmin: true) { app, user, _, token in
            try await app.test(.GET, "/api/api-keys") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let recorded = try await self.events(ofType: "api.request", on: app.db)
            #expect(recorded.count == 1)
            let event = try #require(recorded.first)
            #expect(event.adminBypass == true)
            #expect(event.userID == user.id)
            #expect(event.method == "GET")
            #expect(event.action == "read")
        }
    }

    @Test("Denied requests are audited with their status")
    func deniedRequestIsAudited() async throws {
        try await withApp { app, user, _, token in
            app.spicedbMockAllows = false

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            let recorded = try await self.events(ofType: "api.request", on: app.db)
            #expect(recorded.count == 1)
            let event = try #require(recorded.first)
            #expect(event.status == 403)
            #expect(event.userID == user.id)
            #expect(event.resourceType == "vms")
            #expect(event.action == "create")
        }
    }

    @Test("Mutations denied for missing API-key scope are audited")
    func scopeDeniedMutationIsAudited() async throws {
        try await withApp { app, user, _, _ in
            let readOnlyKey = APIKey.generateAPIKey()
            try await APIKey(
                userID: user.id!,
                name: "read-only",
                keyHash: APIKey.hashAPIKey(readOnlyKey),
                keyPrefix: String(readOnlyKey.prefix(16)),
                scopes: ["read"]
            ).save(on: app.db)

            try await app.test(.POST, "/api/api-keys") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: readOnlyKey)
                try req.content.encode(["name": "should-not-exist"])
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            let recorded = try await self.events(ofType: "api.request", on: app.db)
            #expect(recorded.count == 1)
            let event = try #require(recorded.first)
            #expect(event.status == 403)
            #expect(event.userID == user.id)
        }
    }

    // MARK: - Auth events

    @Test("Logout records an auth.logout event")
    func logoutIsAudited() async throws {
        try await withApp { app, user, org, token in
            try await app.test(.POST, "/auth/logout") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let recorded = try await self.events(ofType: "auth.logout", on: app.db)
            #expect(recorded.count == 1)
            let event = try #require(recorded.first)
            #expect(event.userID == user.id)
            #expect(event.username == "audituser")
            #expect(event.organizationID == org.id)
        }
    }

    // MARK: - Query API

    @Test("Global audit query requires a system administrator")
    func globalQueryRequiresSystemAdmin() async throws {
        try await withApp { app, _, _, token in
            try await app.test(.GET, "/api/audit-events") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("System admin can list and filter all audit events")
    func systemAdminListsAndFilters() async throws {
        try await withApp(systemAdmin: true) { app, _, org, token in
            let otherOrgID = UUID()
            try await AuditEvent(
                from: AuditRecord(eventType: "test.alpha", organizationID: org.id, adminBypass: true)
            ).save(on: app.db)
            try await AuditEvent(
                from: AuditRecord(eventType: "test.alpha", organizationID: otherOrgID)
            ).save(on: app.db)
            try await AuditEvent(
                from: AuditRecord(eventType: "test.beta", organizationID: org.id)
            ).save(on: app.db)

            try await app.test(.GET, "/api/audit-events?eventType=test.alpha") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(AuditEventListResponse.self)
                #expect(decoded.total == 2)
                let types = Set(decoded.events.map(\.eventType))
                #expect(types == ["test.alpha"])
            }

            try await app.test(.GET, "/api/audit-events?eventType=test.alpha&adminOnly=true") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let decoded = try res.content.decode(AuditEventListResponse.self)
                #expect(decoded.total == 1)
                let bypassFlags = decoded.events.map(\.adminBypass)
                #expect(bypassFlags == [true])
            }

            // A far-future lower bound matches nothing.
            try await app.test(
                .GET, "/api/audit-events?eventType=test.alpha&from=2099-01-01T00:00:00Z"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let decoded = try res.content.decode(AuditEventListResponse.self)
                #expect(decoded.total == 0)
            }
        }
    }

    @Test("Org audit query is scoped to the organization and gated on org admin")
    func orgQueryScopedAndGated() async throws {
        try await withApp { app, _, org, token in
            try await AuditEvent(
                from: AuditRecord(eventType: "test.org", organizationID: org.id)
            ).save(on: app.db)
            try await AuditEvent(
                from: AuditRecord(eventType: "test.org", organizationID: UUID())
            ).save(on: app.db)

            try await app.test(.GET, "/api/organizations/\(org.id!)/audit-events") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(AuditEventListResponse.self)
                #expect(decoded.total == 1)
                let orgIDs = Set(decoded.events.map(\.organizationID))
                #expect(orgIDs == [org.id])
            }

            app.spicedbMockAllows = false
            try await app.test(.GET, "/api/organizations/\(org.id!)/audit-events") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Resource parsing

    @Test("Resource references are parsed from API paths")
    func resourceParsing() throws {
        let create = parseResource(path: "/api/vms", method: .POST)
        #expect(create == AuditResourceRef(type: "vms", id: nil, action: "create"))

        let vmID = UUID().uuidString
        let start = parseResource(path: "/api/vms/\(vmID)/start", method: .POST)
        #expect(start == AuditResourceRef(type: "vms", id: vmID, action: "start"))

        let orgID = UUID()
        let deleteGroup = parseResource(
            path: "/api/organizations/\(orgID.uuidString)/groups/g1", method: .DELETE)
        #expect(
            deleteGroup
                == AuditResourceRef(type: "groups", id: "g1", action: "delete", organizationID: orgID))

        let updateOrg = parseResource(path: "/api/organizations/\(orgID.uuidString)", method: .PUT)
        #expect(
            updateOrg
                == AuditResourceRef(
                    type: "organizations", id: orgID.uuidString, action: "update", organizationID: nil))

        let list = parseResource(path: "/api/api-keys", method: .GET)
        #expect(list == AuditResourceRef(type: "api-keys", id: nil, action: "read"))
    }
}
