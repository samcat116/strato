import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport

@testable import App

/// Canonical credential restrictions exercised through production routes.
/// These tests complement the evaluator-level suite by pinning route
/// classification and the login-only restriction backstop.
@Suite("Credential Restriction Routes", .serialized)
final class CredentialRestrictionRouteTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await test(app)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private struct Fixture {
        let org: Organization
        let project: Project
        let vm: VM
        let readOnlyKey: String
        let unrestrictedKey: String
    }

    private func fixture(_ app: Application, admin: Bool = false) async throws -> Fixture {
        let builder = TestDataBuilder(db: app.testPostgres)
        let org = try await builder.createOrganization(name: "Restriction Org")
        let project = try await builder.createProject(
            name: "Restriction Project", description: "d", organization: org)
        let vm = try await builder.createVM(name: "restriction-vm", project: project)
        let user = try await builder.createUser(
            username: "restriction-user", email: "restriction@example.com", isSystemAdmin: admin)
        try await builder.addUserToOrganization(user: user, organization: org, role: "member")
        try await RoleBindingService.grant(
            principalType: .user, principalID: try user.requireID(), role: .admin,
            nodeType: .organization, nodeID: try org.requireID(), createdBy: nil, on: app.testPostgres)
        try await user.replacingCurrentOrganization(try org.requireID()).save(on: app.testPostgres)
        return Fixture(
            org: org,
            project: project,
            vm: vm,
            readOnlyKey: try await user.generateAPIKey(
                on: app, name: "read-only", restriction: .readOnly),
            unrestrictedKey: try await user.generateAPIKey(on: app, name: "unrestricted")
        )
    }

    @Test("A read-only key reads production routes and cannot mutate them")
    func readOnlyKeyIsEnforcedAcrossRouteClasses() async throws {
        try await withApp { app in
            let fixture = try await fixture(app)
            let vmID = try fixture.vm.requireID().uuidString

            for path in ["/api/vms/\(vmID)", "/api/projects", "/api/api-keys"] {
                try await app.test(.GET, path) { request in
                    request.headers.bearerAuthorization = BearerAuthorization(token: fixture.readOnlyKey)
                } afterResponse: { response async in
                    #expect(response.status == .ok, "GET \(path) -> \(response.status)")
                }
            }

            let mutations: [(HTTPMethod, String)] = [
                (.DELETE, "/api/vms/\(vmID)"),
                (.POST, "/api/vms/\(vmID)/start"),
                (.DELETE, "/api/projects/\(try fixture.project.requireID().uuidString)"),
                (.POST, "/api/api-keys"),
            ]
            for (method, path) in mutations {
                try await app.test(method, path) { request in
                    request.headers.bearerAuthorization = BearerAuthorization(token: fixture.readOnlyKey)
                    if method == .POST, path == "/api/api-keys" {
                        try request.content.encode(["name": "escalation"])
                    }
                } afterResponse: { response async in
                    #expect(response.status == .forbidden, "\(method) \(path) -> \(response.status)")
                }
            }
        }
    }

    @Test("An unrestricted key reaches ordinary reads and mutations")
    func unrestrictedKeyIsNotNarrowed() async throws {
        try await withApp { app in
            let fixture = try await fixture(app)
            let vmID = try fixture.vm.requireID().uuidString

            try await app.test(.GET, "/api/vms/\(vmID)") { request in
                request.headers.bearerAuthorization = BearerAuthorization(token: fixture.unrestrictedKey)
            } afterResponse: { response async in
                #expect(response.status == .ok)
            }

            try await app.test(.POST, "/api/api-keys") { request in
                request.headers.bearerAuthorization = BearerAuthorization(token: fixture.unrestrictedKey)
                try request.content.encode(["name": "another"])
            } afterResponse: { response async in
                #expect(response.status == .ok || response.status == .created)
            }
        }
    }

    @Test("Read-only restrictions exclude editor and management actions")
    func readOnlyActionBoundaryIsPinned() {
        for action in ["sandbox:exec", "vm:viewConsole", "vm:exec", "vm:runCommand", "agent:manage"] {
            #expect(!CredentialRestriction.readOnly.permits(action: action))
        }
    }

    @Test("A read-only key sees no agent enrollments because listing requires manage")
    func enrollmentListIsEmptyForReadOnlyCredentials() async throws {
        try await withApp { app in
            let fixture = try await fixture(app, admin: true)
            let enrollment = TestAgentEnrollment(
                agentName: "restriction-agent",
                spiffeID: "spiffe://example.org/agent/restriction-agent",
                organizationScope: .organization(try fixture.org.requireID()))
            _ = try await saveTestAgentEnrollment(enrollment, on: app.testPostgres)

            struct Page: Content { let total: Int }

            try await app.test(.GET, "/api/agent-enrollments") { request in
                request.headers.bearerAuthorization = BearerAuthorization(token: fixture.unrestrictedKey)
            } afterResponse: { response async throws in
                #expect(response.status == .ok)
                #expect(try response.content.decode(Page.self).total == 1)
            }

            try await app.test(.GET, "/api/agent-enrollments") { request in
                request.headers.bearerAuthorization = BearerAuthorization(token: fixture.readOnlyKey)
            } afterResponse: { response async throws in
                #expect(response.status == .ok)
                #expect(try response.content.decode(Page.self).total == 0)
            }
        }
    }

    @Test("Every registered route is covered by the evaluator or restriction backstop")
    func everyRouteIsClassified() async throws {
        try await withApp { app in
            var unclassified: [String] = []
            for route in app.routes.all {
                let path = "/" + route.path.map { "\($0)" }.joined(separator: "/")
                if AuthorizationMiddleware.classify(path: path) == nil {
                    unclassified.append("\(route.method) \(path)")
                }
            }
            #expect(unclassified.isEmpty, "unclassified routes: \(unclassified.joined(separator: ", "))")
        }
    }

    @Test("The restriction backstop refuses login-only escalation")
    func backstopRefusesRestrictedApproval() async throws {
        try await withApp { app in
            let fixture = try await fixture(app)

            try await app.test(.POST, "/api/oauth/device/BCDF-GHJK/approve") { request in
                request.headers.bearerAuthorization = BearerAuthorization(token: fixture.readOnlyKey)
            } afterResponse: { response async in
                #expect(response.status == .forbidden)
            }

            try await app.test(.POST, "/api/oauth/device/BCDF-GHJK/approve") { request in
                request.headers.bearerAuthorization = BearerAuthorization(token: fixture.unrestrictedKey)
            } afterResponse: { response async in
                #expect(response.status == .notFound)
            }
        }
    }
}
