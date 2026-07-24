import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

/// Issue #688: list scoping resolves the caller's projects from their own
/// grants instead of walking every project in the installation.
///
/// The interesting cases are the ones a pure-SQL derivation off `role_bindings`
/// would get wrong, so they are the ones driven here against the real engine: a
/// grant a guardrail takes back must disappear from the list, and access an
/// authored policy hands out with no binding behind it must appear in it.
@Suite("Project Visibility Tests", .serialized)
final class ProjectVisibilityTests {

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

    /// Recompile the policy set against the current database — the store writes
    /// below do not go through the version bump, so drive the rebuild directly.
    private func rebuild(_ app: Application) async throws {
        let version = try await PolicySetVersionService.current(on: app.db)
        await app.cedarPolicySet.rebuild(version: version, on: app.db)
    }

    private func createVolume(
        _ app: Application, name: String, project: Project, createdBy: User
    ) async throws -> Volume {
        let volume = Volume(
            name: name,
            description: "test volume",
            projectID: project.id!,
            size: 1_073_741_824,
            createdByID: createdBy.id!
        )
        try await volume.save(on: app.db)
        return volume
    }

    private func listVolumeNames(_ app: Application, token: String) async throws -> [String] {
        var names: [String] = []
        try await app.test(.GET, "/api/volumes") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
        } afterResponse: { res in
            #expect(res.status == .ok, "\(res.status): \(res.body.string)")
            names = try res.content.decode(PagedResponse<VolumeResponse>.self).items.map(\.name)
        }
        return names
    }

    // MARK: - Role-binding-granted access

    @Test("A list shows only the projects the caller's bindings reach")
    func bindingScopedVisibility() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Vis Org")
            let project = try await builder.createProject(
                name: "Vis Project", description: "d", organization: org)
            let user = try await builder.createUser(username: "vis-user", email: "vis@example.com")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            let token = try await user.generateAPIKey(on: app.db)

            // A whole second organization the caller has no grant in — the
            // rows the old platform-wide walk would have visited.
            let otherOrg = try await builder.createOrganization(name: "Vis Other Org")
            let otherProject = try await builder.createProject(
                name: "Vis Other Project", description: "d", organization: otherOrg)

            _ = try await createVolume(app, name: "mine", project: project, createdBy: user)
            _ = try await createVolume(app, name: "theirs", project: otherProject, createdBy: user)

            let names = try await listVolumeNames(app, token: token)
            #expect(names == ["mine"])
        }
    }

    @Test("A folder binding reaches the projects of nested folders beneath it")
    func folderSubtreeVisibility() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Folder Org")
            let parentFolder = try await builder.createOU(
                name: "Parent", description: "d", organization: org)
            let childFolder = try await builder.createOU(
                name: "Child", description: "d", organization: org, parentOU: parentFolder)
            let nested = try await builder.createProject(
                name: "Nested Project", description: "d", ou: childFolder)
            let sibling = try await builder.createProject(
                name: "Sibling Project", description: "d", organization: org)

            let user = try await builder.createUser(
                username: "folder-user", email: "folder@example.com")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .organizationalUnit, nodeID: parentFolder.id!, createdBy: nil, on: app.db)
            let token = try await user.generateAPIKey(on: app.db)

            _ = try await createVolume(app, name: "nested-vol", project: nested, createdBy: user)
            _ = try await createVolume(app, name: "sibling-vol", project: sibling, createdBy: user)

            let names = try await listVolumeNames(app, token: token)
            #expect(names == ["nested-vol"])
        }
    }

    @Test("A caller with no grant anywhere sees nothing")
    func noGrantsSeesNothing() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Empty Org")
            let project = try await builder.createProject(
                name: "Empty Project", description: "d", organization: org)

            // A bare org member: membership grants org:read + project:create
            // only, so no binding makes the project readable.
            let member = try await builder.createUser(
                username: "bare-member", email: "bare@example.com")
            try await builder.addUserToOrganization(user: member, organization: org, role: "member")
            let token = try await member.generateAPIKey(on: app.db)
            _ = try await createVolume(app, name: "unreachable", project: project, createdBy: member)

            #expect(try await listVolumeNames(app, token: token).isEmpty)
        }
    }

    // MARK: - The evaluator has the last word

    @Test("A guardrail forbidding project:read removes the project from the list")
    func guardrailNarrowsAGrantedProject() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Ceiling Org")
            let visible = try await builder.createProject(
                name: "Ceiling Visible", description: "d", organization: org)
            let ceilinged = try await builder.createProject(
                name: "Ceiling Hidden", description: "d", organization: org)
            let user = try await builder.createUser(
                username: "ceiling-user", email: "ceiling@example.com")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            let token = try await user.generateAPIKey(on: app.db)

            _ = try await createVolume(app, name: "visible-vol", project: visible, createdBy: user)
            _ = try await createVolume(app, name: "hidden-vol", project: ceilinged, createdBy: user)

            // The binding still grants project:read on both; the ceiling takes
            // it back on one. A derivation that read only `role_bindings` would
            // show both.
            _ = try await GuardrailStore.create(
                name: "no-project-read", description: nil, effect: nil,
                node: IAMNode(type: .project, id: ceilinged.id!),
                actions: ["project:read"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            try await rebuild(app)

            let names = try await listVolumeNames(app, token: token)
            #expect(names == ["visible-vol"])
        }
    }

    @Test("An authored permit policy makes a project visible with no binding behind it")
    func authoredPolicyGrantedVisibility() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Authored Org")
            let project = try await builder.createProject(
                name: "Authored Project", description: "d", organization: org)

            // A bare member: no role binding reaches the project at all.
            let user = try await builder.createUser(
                username: "authored-user", email: "authored@example.com")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            let token = try await user.generateAPIKey(on: app.db)
            _ = try await createVolume(app, name: "policy-vol", project: project, createdBy: user)

            #expect(try await listVolumeNames(app, token: token).isEmpty)

            let id = UUID()
            let cedarText = """
                permit (
                    principal == User::"\(user.id!.uuidString.lowercased())",
                    action == Action::"project:read",
                    resource in Project::"\(project.id!.uuidString.lowercased())"
                );
                """
            let prepared = try await PolicyStore.prepare(
                id: id, cedarText: cedarText, ownerType: .organization, ownerID: org.id!,
                engine: app.cedarEngine, on: app.db)
            _ = try await PolicyStore.create(
                id: id, name: "read-one-project", description: nil, ownerType: .organization,
                ownerID: org.id!, prepared: prepared, createdBy: nil, enabled: true, on: app.db)
            try await rebuild(app)

            let names = try await listVolumeNames(app, token: token)
            #expect(names == ["policy-vol"])
        }
    }

    // MARK: - System admins

    @Test("A system admin sees every project, and a guardrail still narrows them")
    func systemAdminVisibility() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let orgA = try await builder.createOrganization(name: "Admin Org A")
            let orgB = try await builder.createOrganization(name: "Admin Org B")
            let projectA = try await builder.createProject(
                name: "Admin Project A", description: "d", organization: orgA)
            let projectB = try await builder.createProject(
                name: "Admin Project B", description: "d", organization: orgB)
            let admin = try await builder.createUser(
                username: "vis-admin", email: "vis-admin@example.com", isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app.db)
            _ = try await createVolume(app, name: "a-vol", project: projectA, createdBy: admin)
            _ = try await createVolume(app, name: "b-vol", project: projectB, createdBy: admin)

            // No binding anywhere: the admin's reach is the tier-1 policy, so
            // there is no candidate set to narrow by.
            let names = try await listVolumeNames(app, token: token)
            #expect(Set(names) == ["a-vol", "b-vol"])

            _ = try await GuardrailStore.create(
                name: "admin-no-project-read", description: nil, effect: nil,
                node: IAMNode(type: .project, id: projectB.id!),
                actions: ["project:read"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            try await rebuild(app)

            #expect(try await listVolumeNames(app, token: token) == ["a-vol"])
        }
    }

    // MARK: - Global networks

    @Test("Global networks stay visible to a caller who reaches no project")
    func globalNetworksSurviveScoping() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Global Net Org")
            let project = try await builder.createProject(
                name: "Global Net Project", description: "d", organization: org)
            let member = try await builder.createUser(
                username: "net-bare", email: "net-bare@example.com")
            try await builder.addUserToOrganization(user: member, organization: org, role: "member")
            let token = try await member.generateAPIKey(on: app.db)

            let global = LogicalNetwork(
                name: "global-net", subnet: "10.50.0.0/24", gateway: "10.50.0.1",
                projectID: nil, createdByID: nil)
            try await global.save(on: app.db)
            let scoped = LogicalNetwork(
                name: "scoped-net", subnet: "10.51.0.0/24", gateway: "10.51.0.1",
                projectID: project.id!, createdByID: nil)
            try await scoped.save(on: app.db)

            try await app.test(.GET, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.status): \(res.body.string)")
                let names = try res.content.decode(PagedResponse<NetworkResponse>.self).items.map(\.name)
                #expect(names.contains("global-net"))
                #expect(!names.contains("scoped-net"))
            }
        }
    }

    // MARK: - Cost

    @Test("Resolution does not depend on the platform-wide project count")
    func resolutionIgnoresUnreachableProjects() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Cost Org")
            let project = try await builder.createProject(
                name: "Cost Project", description: "d", organization: org)
            let user = try await builder.createUser(username: "cost-user", email: "cost@example.com")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            _ = try await createVolume(app, name: "cost-vol", project: project, createdBy: user)

            // Fifty projects in an organization the caller has no grant in.
            // Under the old helper each one cost a full evaluation; here none
            // of them is a candidate, so none is ever decided.
            let otherOrg = try await builder.createOrganization(name: "Cost Other Org")
            for index in 0..<50 {
                _ = try await builder.createProject(
                    name: "Cost Filler \(index)", description: "d", organization: otherOrg)
            }

            let visibility = try await ProjectVisibility.resolve(
                on: Request.forVisibilityTesting(app: app, user: user))
            #expect(visibility.candidateProjectIDs == [project.id!])
        }
    }
}

extension Request {
    /// A bare authenticated request, for exercising `ProjectVisibility.resolve`
    /// without going through a route.
    fileprivate static func forVisibilityTesting(app: Application, user: User) -> Request {
        let request = Request(application: app, on: app.eventLoopGroup.next())
        request.auth.login(user)
        return request
    }
}
