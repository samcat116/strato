import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// Regression tests for issue #163 (the middleware guarded `/vms` while VM
/// routes live under `/api/vms`, so per-object authorization was dead code),
/// updated for the #482 cutover: authorization is now the Cedar evaluator
/// answering from `role_bindings`, so denial is the *absence of a binding*
/// rather than a mock verdict, and an unclassified path is denied outright by
/// the default-deny middleware.
@Suite("VM Authorization Tests", .serialized)
final class VMAuthorizationTests {

    /// Boots a configured test app with a non-admin org *member* (bare
    /// membership carries no role binding, so they can list but not read any
    /// VM), plus an org, a project, and one VM.
    private func withVMTestApp(
        _ test: (Application, User, VM, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "vmauthuser",
                email: "vmauth@example.com",
                displayName: "VM Auth User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "VM Auth Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "VM Auth Project",
                description: "Project for VM authorization tests",
                organization: org
            )
            let vm = try await builder.createVM(name: "auth-vm", project: project)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, vm, project, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// Grant `role` to `user` on `project` — the binding the evaluator answers
    /// from.
    private func grant(_ role: IAMRole, to user: User, onProject project: Project, app: Application)
        async throws
    {
        try await RoleBindingService.grant(
            principalType: .user,
            principalID: user.id!,
            role: role,
            nodeType: .project,
            nodeID: project.id!,
            createdBy: nil,
            on: app.db
        )
    }

    @Test("GET /api/vms?organization_id= narrows the list to that org's projects")
    func indexFilteredByOrganization() async throws {
        try await withVMTestApp { app, user, vm, project, token in
            // Visibility comes from a viewer binding on the project; the VM in
            // another organization's project stays invisible because no
            // binding reaches it.
            try await self.grant(.viewer, to: user, onProject: project, app: app)

            let builder = TestDataBuilder(db: app.db)
            let otherOrg = try await builder.createOrganization(name: "Other VM Org")
            let otherProject = try await builder.createProject(
                name: "Other VM Project", description: "elsewhere", organization: otherOrg)
            _ = try await builder.createVM(name: "other-vm", project: otherProject)

            let orgID = try #require(user.currentOrganizationId)
            try await app.test(.GET, "/api/vms?organization_id=\(orgID.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let vms = try res.content.decode([VMDetailResponse].self)
                #expect(vms.map(\.name) == [vm.name])
            }
        }
    }

    @Test("GET /api/vms/:id is denied (403) without a binding granting read")
    func showDeniedWhenNoPermission() async throws {
        try await withVMTestApp { app, _, vm, _, token in
            try await app.test(.GET, "/api/vms/\(vm.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                // Bare org membership grants org:read + project:create only —
                // no vm:read anywhere, so the middleware's object check denies.
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("GET /api/vms/:id succeeds (200) with a viewer binding on the project")
    func showAllowedWhenPermitted() async throws {
        try await withVMTestApp { app, user, vm, project, token in
            try await self.grant(.viewer, to: user, onProject: project, app: app)

            try await app.test(.GET, "/api/vms/\(vm.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("POST /api/vms/:id/start is denied (403) for a viewer (vm:start is operator+)")
    func startActionDeniedWhenNoPermission() async throws {
        try await withVMTestApp { app, user, vm, project, token in
            // A viewer can read the VM but vm:start belongs to operator and
            // above — the role nesting, not the mock, is what denies here.
            try await self.grant(.viewer, to: user, onProject: project, app: app)

            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("GET /api/vms/:id/logs is denied (403) without a binding granting read")
    func logsDeniedWhenNoPermission() async throws {
        try await withVMTestApp { app, _, vm, _, token in
            try await app.test(.GET, "/api/vms/\(vm.id!)/logs") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Direct middleware tests
    //
    // These isolate `AuthorizationMiddleware` from the route handlers so the
    // `/api/vms` prefix guard is pinned independently of the per-handler
    // `authorizedVM` checks, and the default-deny behavior for unclassified
    // paths is pinned at all.

    /// A `next` responder that unconditionally succeeds, standing in for the route
    /// handler so any 403 must originate from the middleware itself.
    private struct OKResponder: AsyncResponder {
        func respond(to request: Request) async throws -> Response {
            Response(status: .ok)
        }
    }

    private func runMiddleware(
        _ app: Application,
        user: User,
        path: String,
        method: HTTPMethod = .GET
    ) async throws -> Response {
        let req = Request(
            application: app,
            method: method,
            url: URI(path: path),
            on: app.eventLoopGroup.next()
        )
        req.auth.login(user)
        return try await AuthorizationMiddleware().respond(to: req, chainingTo: OKResponder())
    }

    @Test("Middleware runs its per-object check for the /api/vms prefix")
    func middlewareGuardsApiVmsPrefix() async throws {
        try await withVMTestApp { app, user, vm, project, _ in
            // Denied: no binding grants vm:read, so the middleware rejects
            // before reaching the handler.
            await #expect(throws: Abort.self) {
                _ = try await self.runMiddleware(app, user: user, path: "/api/vms/\(vm.id!)")
            }

            // Granted: with a viewer binding the middleware lets the request
            // through to `next` (200).
            try await self.grant(.viewer, to: user, onProject: project, app: app)
            let res = try await runMiddleware(app, user: user, path: "/api/vms/\(vm.id!)")
            #expect(res.status == .ok)
        }
    }

    @Test("Middleware denies the unclassified bare /vms prefix outright")
    func middlewareDeniesBareVmsPrefix() async throws {
        try await withVMTestApp { app, user, vm, project, _ in
            // Issue #163's bug was `/vms` slipping through unguarded. Under
            // default-deny (#482) the failure mode is gone structurally: a
            // path outside every route class is denied even for a user who
            // could read the VM through the real route.
            try await self.grant(.viewer, to: user, onProject: project, app: app)
            await #expect(throws: Abort.self) {
                _ = try await self.runMiddleware(app, user: user, path: "/vms/\(vm.id!)")
            }
        }
    }
}
