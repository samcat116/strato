import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport

@testable import App

/// STR-115's load-bearing claim: an existing credential behaves exactly as it
/// did when its `read`/`write`/`admin` scopes were enforced by
/// `APIKeyScopeMiddleware` from the HTTP method — except for three deliberate
/// tightenings, which are asserted here too so they cannot happen by accident.
///
/// These drive real production routes, not ad-hoc test routes: the whole point
/// is that the *route table* still behaves, and a route class nobody thought
/// about is exactly how a compatibility break would arrive.
@Suite("Credential Scope Compatibility", .serialized)
final class CredentialScopeCompatibilityTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private struct Fixture {
        let user: User
        let org: Organization
        let project: Project
        let vm: VM
        let readKey: String
        let writeKey: String
    }

    private func fixture(_ app: Application, admin: Bool = false) async throws -> Fixture {
        let builder = TestDataBuilder(db: app.db)
        let org = try await builder.createOrganization(name: "Compat Org")
        let project = try await builder.createProject(
            name: "Compat Project", description: "d", organization: org)
        let vm = try await builder.createVM(name: "compat-vm", project: project)
        let user = try await builder.createUser(
            username: "compat-user", email: "compat@example.com", isSystemAdmin: admin)
        try await builder.addUserToOrganization(user: user, organization: org, role: "member")
        try await RoleBindingService.grant(
            principalType: .user, principalID: try user.requireID(), role: .admin,
            nodeType: .organization, nodeID: try org.requireID(), createdBy: nil, on: app.db)
        return Fixture(
            user: user,
            org: org,
            project: project,
            vm: vm,
            readKey: try await user.generateAPIKey(on: app.db, name: "read", scopes: ["read"]),
            writeKey: try await user.generateAPIKey(on: app.db, name: "write", scopes: ["write"])
        )
    }

    // MARK: - Legacy `read`: reads still work

    @Test("A read-scoped key still reads across the route classes it could before")
    func readKeyStillReads() async throws {
        try await withApp { app in
            let f = try await fixture(app)
            let vmID = try f.vm.requireID().uuidString

            // `.resource` (middleware-evaluated), `.handlerChecked`, and
            // `.loginOnly` — one of each, since the classes are what a
            // compatibility break would split on.
            for path in ["/api/vms/\(vmID)", "/api/projects", "/api/api-keys"] {
                try await app.test(.GET, path) { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: f.readKey)
                } afterResponse: { res async in
                    #expect(res.status == .ok, "GET \(path) → \(res.status)")
                }
            }
        }
    }

    @Test("A read-scoped key is refused mutations on every route class")
    func readKeyCannotMutate() async throws {
        try await withApp { app in
            let f = try await fixture(app)
            let vmID = try f.vm.requireID().uuidString

            // `.resource`, `.handlerChecked`, and the `.loginOnly` escalation
            // that matters most: minting a key wider than the one asking.
            let mutations: [(HTTPMethod, String)] = [
                (.DELETE, "/api/vms/\(vmID)"),
                (.POST, "/api/vms/\(vmID)/start"),
                (.DELETE, "/api/projects/\(try f.project.requireID().uuidString)"),
                (.POST, "/api/api-keys"),
            ]
            for (method, path) in mutations {
                try await app.test(method, path) { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: f.readKey)
                    if method == .POST, path == "/api/api-keys" {
                        try req.content.encode(["name": "escalation"])
                    }
                } afterResponse: { res async in
                    #expect(res.status == .forbidden, "\(method) \(path) → \(res.status)")
                }
            }
        }
    }

    // MARK: - Legacy `write`: unchanged

    @Test("A write-scoped key is unaffected: it reads and mutates as before")
    func writeKeyUnaffected() async throws {
        try await withApp { app in
            let f = try await fixture(app)
            let vmID = try f.vm.requireID().uuidString

            try await app.test(.GET, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.writeKey)
            } afterResponse: { res async in
                #expect(res.status == .ok)
            }

            try await app.test(.POST, "/api/api-keys") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.writeKey)
                try req.content.encode(["name": "another"])
            } afterResponse: { res async in
                #expect(res.status == .ok || res.status == .created, "→ \(res.status)")
            }
        }
    }

    // MARK: - The accepted tightenings

    /// The VM console upgrade is a GET, so the scope middleware scored it
    /// `read` and a hand-written carve-out had to re-deny it — for API keys
    /// only, never for CLI sessions. Now the check resolves to
    /// `vm:viewConsole`, an editor action, and the evaluator denies both.
    @Test("A read-scoped key can no longer open a VM console")
    func readKeyCannotOpenConsole() async throws {
        try await withApp { app in
            let f = try await fixture(app)
            let vmID = try f.vm.requireID().uuidString

            try await app.test(.POST, "/api/vms/\(vmID)/console/vnc") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.readKey)
            } afterResponse: { res async in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("The tightened actions are deliberately outside the read action set")
    func tighteningsArePinned() {
        let read = CredentialRestriction(legacyScopes: ["read"])
        for action in ["sandbox:exec", "vm:viewConsole", "vm:exec", "vm:runCommand", "agent:manage"] {
            #expect(!read.permits(action: action), "\(action) is reachable by a read credential")
        }
    }

    /// The fourth tightening, and the only one that does not surface as a 403.
    /// `GET /api/agent-enrollments` gates its *read* on `agent:manage` — the
    /// one list in the app that does — so a read-restricted credential matches
    /// no row and gets an empty page, which reads exactly like "there are no
    /// enrollments". Pinned here because the shape is the surprise, and because
    /// giving the listing a read-shaped action later should break this test on
    /// purpose.
    @Test("A read-scoped key sees an empty enrollment list, not a 403")
    func enrollmentListIsEmptyForReadCredentials() async throws {
        try await withApp { app in
            let f = try await fixture(app, admin: true)
            let enrollment = AgentEnrollment(
                agentName: "compat-agent",
                spiffeID: "spiffe://example.org/agent/compat-agent",
                organizationScope: .organization(try f.org.requireID()))
            try await enrollment.save(on: app.db)

            struct Page: Content { let total: Int }

            // The row is visible to the same user through an unrestricted
            // credential, so the empty page below is the credential's doing and
            // not an empty table.
            try await app.test(.GET, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.writeKey)
            } afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(Page.self).total == 1)
            }

            try await app.test(.GET, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.readKey)
            } afterResponse: { res async throws in
                // 200 with nothing in it — indistinguishable from "there are no
                // enrollments", which is why this one is called out in the docs
                // rather than left to be discovered.
                #expect(res.status == .ok)
                #expect(try res.content.decode(Page.self).total == 0)
            }
        }
    }

    // MARK: - The structural guard

    /// Every mutation a restricted credential can make must be seen by one of
    /// the two systems: the evaluator (`.resource`, `.handlerChecked`) or the
    /// backstop (`.loginOnly`, `.isPublic`). A route in neither is a mutation
    /// that escapes both, which is the exact defect STR-115 exists to close —
    /// so the classification is asserted over the whole registered route table
    /// rather than per handler.
    @Test("No registered route escapes both the evaluator and the restriction backstop")
    func everyRouteIsCoveredByOneSystemOrTheOther() async throws {
        try await withApp { app in
            var unclassified: [String] = []
            for route in app.routes.all {
                let path = "/" + route.path.map { "\($0)" }.joined(separator: "/")
                // The middleware and the classifier read only constant
                // segments, so a registered pattern classifies like a concrete
                // path — the same property `assertAllRoutesClassified` relies
                // on.
                if AuthorizationMiddleware.classify(path: path) == nil {
                    unclassified.append("\(route.method) \(path)")
                }
            }
            #expect(unclassified.isEmpty, "unclassified routes: \(unclassified.joined(separator: ", "))")
        }
    }

    /// The backstop's rule, stated as a table so a change to it is a diff
    /// rather than a surprise: a restricted credential loses mutations on the
    /// classes that authorize by row scoping, and keeps everything else,
    /// because the evaluator intersects the restriction there itself.
    @Test("The backstop refuses restricted mutations exactly on the non-evaluator classes")
    func backstopCoversTheRightClasses() async throws {
        try await withApp { app in
            let f = try await fixture(app)
            // `/api/oauth` is `.loginOnly`; approving a device authorization
            // with a restricted credential would hand out a session the
            // credential itself could not mint.
            try await app.test(.POST, "/api/oauth/device/BCDF-GHJK/approve") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.readKey)
            } afterResponse: { res async in
                // Refused for the credential, not for the (nonexistent) code:
                // a 404 here would mean the backstop let it through to the
                // lookup.
                #expect(res.status == .forbidden)
            }

            // A write-scoped credential is unrestricted, so it reaches the
            // handler and gets the ordinary "no such code" answer.
            try await app.test(.POST, "/api/oauth/device/BCDF-GHJK/approve") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.writeKey)
            } afterResponse: { res async in
                #expect(res.status == .notFound)
            }
        }
    }
}
