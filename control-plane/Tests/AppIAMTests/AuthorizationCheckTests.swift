import Fluent
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Tests the batch "can I?" endpoint (`POST /api/authorization/check`) that the
/// frontend uses to gate UI. Since cutover (#482) the caller-scoped form is
/// answered by the authoritative Cedar evaluator, so verdicts come from real
/// bindings — not a mock.
@Suite("Authorization Check Endpoint Tests", .serialized)
final class AuthorizationCheckTests {

    private func withApp(
        systemAdmin: Bool = false,
        _ test: (Application, User, Organization, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "authcheckuser",
                email: "authcheck@example.com",
                displayName: "Auth Check User",
                isSystemAdmin: systemAdmin
            )
            let org = try await builder.createOrganization(name: "Auth Check Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)
            let project = try await builder.createProject(
                name: "Auth Check Project", description: "d", organization: org)

            let token = try await user.generateAPIKey(on: app.db)
            try await test(app, user, org, project, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func item(key: String, action: String, node: IAMNode) -> AuthorizationController.ActionCheckItem {
        AuthorizationController.ActionCheckItem(key: key, action: action, node: node)
    }

    @Test("Per-resource verdicts reflect the caller's bindings per key")
    func perResourceDenial() async throws {
        try await withApp { app, user, org, project, token in
            // Viewer on the project, bare member of the org: project read is
            // granted by the binding, org member management is not.
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)

            try await app.test(.POST, "/api/authorization/check") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AuthorizationController.CheckRequest(checks: [
                        self.item(
                            key: "manage_org", action: "org:update",
                            node: IAMNode(type: .organization, id: org.id!)),
                        self.item(
                            key: "view_proj", action: "project:read",
                            node: IAMNode(type: .project, id: project.id!)),
                    ]))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(AuthorizationController.CheckResponse.self)
                let orgResult = decoded.results["manage_org"]
                let projResult = decoded.results["view_proj"]
                #expect(orgResult == false)
                #expect(projResult == true)
            }
        }
    }

    @Test("Canonical actions and typed nodes are evaluated directly")
    func canonicalActionVocabulary() async throws {
        try await withApp { app, user, org, project, token in
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)

            try await app.test(.POST, "/api/authorization/check") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AuthorizationController.CheckRequest(checks: [
                        self.item(
                            key: "read", action: "project:read",
                            node: IAMNode(type: .project, id: project.id!)),
                        self.item(
                            key: "update", action: "project:update",
                            node: IAMNode(type: .project, id: project.id!)),
                        self.item(
                            key: "org_read", action: "org:read",
                            node: IAMNode(type: .organization, id: org.id!)),
                    ]))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(AuthorizationController.CheckResponse.self)
                #expect(decoded.results["read"] == true)
                #expect(decoded.results["update"] == false)
                // Membership-derived, no binding behind it.
                #expect(decoded.results["org_read"] == true)
            }
        }
    }

    @Test("System admin gets all-true through the platform policy")
    func systemAdminAllTrue() async throws {
        try await withApp(systemAdmin: true) { app, _, org, project, token in
            try await app.test(.POST, "/api/authorization/check") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AuthorizationController.CheckRequest(checks: [
                        self.item(
                            key: "a", action: "org:update",
                            node: IAMNode(type: .organization, id: org.id!)),
                        self.item(
                            key: "b", action: "project:update",
                            node: IAMNode(type: .project, id: project.id!)),
                    ]))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(AuthorizationController.CheckResponse.self)
                let a = decoded.results["a"]
                let b = decoded.results["b"]
                #expect(a == true)
                #expect(b == true)
            }
        }
    }

    @Test("Unauthenticated request is rejected (401)")
    func unauthenticated() async throws {
        try await withApp { app, _, org, _, _ in
            try await app.test(.POST, "/api/authorization/check") { req in
                try req.content.encode(
                    AuthorizationController.CheckRequest(checks: [
                        self.item(
                            key: "a", action: "org:read",
                            node: IAMNode(type: .organization, id: org.id!))
                    ]))
            } afterResponse: { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("More than 50 checks is rejected (400)")
    func tooManyChecks() async throws {
        try await withApp { app, _, _, project, token in
            let items = (0..<51).map {
                self.item(
                    key: "k\($0)", action: "project:read",
                    node: IAMNode(type: .project, id: project.id!))
            }

            try await app.test(.POST, "/api/authorization/check") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AuthorizationController.CheckRequest(checks: items))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }
}
