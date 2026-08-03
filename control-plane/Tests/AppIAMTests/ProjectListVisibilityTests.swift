import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Issue #870: the list endpoints that hand back projects ask the evaluator
/// which ones the caller may read, instead of filtering on organization
/// membership and returning everything in scope.
///
/// The invariant under test is the one the Cedar rewrite states and the item
/// routes already keep: **bare org membership grants `org:read` and
/// `project:create` — nothing else**. So the caller driven through every
/// endpoint here is a bare member: they are allowed into the organization, and
/// must still be shown none of its contents. The paired assertion each time is
/// that the same caller's `GET /api/projects/{id}` answers 403 — a list and the
/// item read that follows it are the same question, and the bug was that only
/// one of them was asked.
@Suite("Project List Visibility Tests", .serialized)
final class ProjectListVisibilityTests {

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

    /// An organization with a project at its root and one under a folder, plus a
    /// bare member of it holding no role binding at all.
    private struct Fixture {
        let organization: Organization
        let folder: OrganizationalUnit
        let rootProject: Project
        let folderProject: Project
        let member: User
        let token: String
    }

    private func makeFixture(_ app: Application, prefix: String) async throws -> Fixture {
        let builder = TestDataBuilder(db: app.db)
        let organization = try await builder.createOrganization(name: "\(prefix) Org")
        let folder = try await builder.createOU(
            name: "\(prefix) Folder", description: "d", organization: organization)
        let rootProject = try await builder.createProject(
            name: "\(prefix) Root Project", description: "d", organization: organization)
        let folderProject = try await builder.createProject(
            name: "\(prefix) Folder Project", description: "d", ou: folder)

        let member = try await builder.createUser(
            username: "\(prefix.lowercased())-member", email: "\(prefix.lowercased())@example.com")
        try await builder.addUserToOrganization(user: member, organization: organization, role: "member")

        return Fixture(
            organization: organization,
            folder: folder,
            rootProject: rootProject,
            folderProject: folderProject,
            member: member,
            token: try await member.generateAPIKey(on: app.db)
        )
    }

    private func projectNames(
        _ app: Application, _ path: String, token: String
    ) async throws -> [String] {
        var names: [String] = []
        try await app.test(.GET, path) { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
        } afterResponse: { res in
            #expect(res.status == .ok, "\(path) -> \(res.status): \(res.body.string)")
            names = try res.content.decode([ProjectResponse].self).map(\.name)
        }
        return names
    }

    private func expectItemReadForbidden(
        _ app: Application, project: Project, token: String
    ) async throws {
        try await app.test(.GET, "/api/projects/\(project.id!)") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
        } afterResponse: { res in
            #expect(res.status == .forbidden, "\(res.status): \(res.body.string)")
        }
    }

    // MARK: - The three project list endpoints

    @Test("A bare org member is shown no projects by any of the three list endpoints")
    func bareMemberSeesNoProjects() async throws {
        try await withApp { app in
            let fixture = try await makeFixture(app, prefix: "Bare")
            let organizationID = fixture.organization.id!
            let folderID = fixture.folder.id!

            // Every individual read is already denied; the lists used to hand
            // back the same rows anyway.
            try await expectItemReadForbidden(app, project: fixture.rootProject, token: fixture.token)
            try await expectItemReadForbidden(app, project: fixture.folderProject, token: fixture.token)

            #expect(try await projectNames(app, "/api/projects", token: fixture.token).isEmpty)
            #expect(
                try await projectNames(
                    app, "/api/organizations/\(organizationID)/projects", token: fixture.token
                ).isEmpty)
            #expect(
                try await projectNames(
                    app, "/api/organizations/\(organizationID)/ous/\(folderID)/projects", token: fixture.token
                ).isEmpty)
        }
    }

    @Test("A project binding shows that project and no sibling")
    func projectBindingShowsOnlyItsOwnProject() async throws {
        try await withApp { app in
            let fixture = try await makeFixture(app, prefix: "Scoped")
            let organizationID = fixture.organization.id!

            try await RoleBindingService.grant(
                principalType: .user, principalID: fixture.member.id!, role: .admin,
                nodeType: .project, nodeID: fixture.folderProject.id!, createdBy: nil, on: app.db)

            // The sibling at org root stays denied, and stays out of the lists.
            try await expectItemReadForbidden(app, project: fixture.rootProject, token: fixture.token)

            #expect(
                try await projectNames(app, "/api/projects", token: fixture.token)
                    == ["Scoped Folder Project"])
            #expect(
                try await projectNames(
                    app, "/api/organizations/\(organizationID)/projects", token: fixture.token
                ) == ["Scoped Folder Project"])
            #expect(
                try await projectNames(
                    app, "/api/organizations/\(organizationID)/ous/\(fixture.folder.id!)/projects",
                    token: fixture.token
                ) == ["Scoped Folder Project"])
        }
    }

    @Test("A folder binding does not reach a sibling folder or the organization root")
    func folderBindingDoesNotReachSiblings() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let fixture = try await makeFixture(app, prefix: "Sibling")
            let organizationID = fixture.organization.id!

            let siblingFolder = try await builder.createOU(
                name: "Sibling Folder", description: "d", organization: fixture.organization)
            let siblingProject = try await builder.createProject(
                name: "Sibling Folder Project", description: "d", ou: siblingFolder)

            try await RoleBindingService.grant(
                principalType: .user, principalID: fixture.member.id!, role: .admin,
                nodeType: .organizationalUnit, nodeID: fixture.folder.id!, createdBy: nil, on: app.db)

            try await expectItemReadForbidden(app, project: siblingProject, token: fixture.token)
            try await expectItemReadForbidden(app, project: fixture.rootProject, token: fixture.token)

            #expect(
                try await projectNames(app, "/api/projects", token: fixture.token)
                    == ["Sibling Folder Project"])
            #expect(
                try await projectNames(
                    app, "/api/organizations/\(organizationID)/projects", token: fixture.token
                ) == ["Sibling Folder Project"])
            // The sibling folder's own list is empty rather than forbidden: the
            // folder is in an organization the caller may view, and it holds
            // nothing they may read.
            #expect(
                try await projectNames(
                    app, "/api/organizations/\(organizationID)/ous/\(siblingFolder.id!)/projects",
                    token: fixture.token
                ).isEmpty)
        }
    }

    @Test("A guardrail that takes back project:read removes the project from the list")
    func guardrailNarrowsTheProjectList() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let organization = try await builder.createOrganization(name: "Guardrail List Org")
            _ = try await builder.createProject(
                name: "Guardrail Visible", description: "d", organization: organization)
            let hidden = try await builder.createProject(
                name: "Guardrail Hidden", description: "d", organization: organization)
            let admin = try await builder.createUser(
                username: "guardrail-lister", email: "guardrail-lister@example.com")
            try await builder.addUserToOrganization(user: admin, organization: organization, role: "admin")
            let token = try await admin.generateAPIKey(on: app.db)

            #expect(
                try await projectNames(app, "/api/projects", token: token)
                    == ["Guardrail Hidden", "Guardrail Visible"])

            _ = try await GuardrailStore.create(
                name: "list-no-project-read", description: nil, effect: nil,
                node: IAMNode(type: .project, id: hidden.id!),
                actions: ["project:read"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            try await expectItemReadForbidden(app, project: hidden, token: token)
            #expect(try await projectNames(app, "/api/projects", token: token) == ["Guardrail Visible"])
        }
    }

    // MARK: - The other doors onto the same inventory

    @Test("The organization hierarchy tree hides projects, VMs and folders the caller cannot read")
    func hierarchyTreeIsScopedToTheCaller() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let fixture = try await makeFixture(app, prefix: "Tree")
            _ = try await builder.createVM(name: "tree-vm", project: fixture.rootProject)

            try await app.test(.GET, "/api/organizations/\(fixture.organization.id!)/hierarchy") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.status): \(res.body.string)")
                let tree = try res.content.decode(OrganizationHierarchyResponse.self)
                #expect(tree.organization.projects.isEmpty)
                #expect(tree.organization.organizationalUnits.isEmpty)
                #expect(tree.stats.totalProjects == 0)
                #expect(tree.stats.totalVMs == 0)
            }

            // The org-wide resource dump is the same inventory by another name.
            try await app.test(.GET, "/api/organizations/\(fixture.organization.id!)/resources") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.status): \(res.body.string)")
                let resources = try res.content.decode(OrganizationResourcesResponse.self)
                #expect(resources.projects.isEmpty)
                #expect(resources.vms.isEmpty)
                #expect(resources.organizationalUnits.isEmpty)
            }
        }
    }

    @Test("An org admin still sees the whole tree")
    func hierarchyTreeIsUnchangedForAnAdmin() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let fixture = try await makeFixture(app, prefix: "AdminTree")
            _ = try await builder.createVM(name: "admin-tree-vm", project: fixture.rootProject)

            let admin = try await builder.createUser(
                username: "tree-admin", email: "tree-admin@example.com")
            try await builder.addUserToOrganization(
                user: admin, organization: fixture.organization, role: "admin")
            let token = try await admin.generateAPIKey(on: app.db)

            try await app.test(.GET, "/api/organizations/\(fixture.organization.id!)/hierarchy") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.status): \(res.body.string)")
                let tree = try res.content.decode(OrganizationHierarchyResponse.self)
                #expect(tree.stats.totalProjects == 2)
                #expect(tree.stats.totalOUs == 1)
                #expect(tree.stats.totalVMs == 1)
                #expect(tree.organization.organizationalUnits.first?.projects.count == 1)
            }
        }
    }

    @Test("Hierarchy search does not confirm the existence of projects the caller cannot read")
    func hierarchySearchIsScopedToTheCaller() async throws {
        try await withApp { app in
            let fixture = try await makeFixture(app, prefix: "Search")
            let organizationID = fixture.organization.id!

            for path in [
                "/api/organizations/\(organizationID)/search?q=Search",
                "/api/hierarchy/search?q=Search",
            ] {
                try await app.test(.GET, path) { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                } afterResponse: { res in
                    #expect(res.status == .ok, "\(path) -> \(res.status): \(res.body.string)")
                    let response = try res.content.decode(HierarchySearchResponse.self)
                    #expect(response.results.isEmpty, "\(path) leaked \(response.results.map(\.name))")
                    #expect(response.totalResults == 0)
                }
            }

            // A binding on one project makes exactly that project findable.
            try await RoleBindingService.grant(
                principalType: .user, principalID: fixture.member.id!, role: .viewer,
                nodeType: .project, nodeID: fixture.folderProject.id!, createdBy: nil, on: app.db)

            try await app.test(.GET, "/api/hierarchy/search?q=Search") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.status): \(res.body.string)")
                let response = try res.content.decode(HierarchySearchResponse.self)
                #expect(response.results.map(\.name) == ["Search Folder Project"])
            }
        }
    }

    @Test("The folder list is decided per folder, not by organization membership")
    func folderListIsScopedToTheCaller() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let fixture = try await makeFixture(app, prefix: "Folder")
            let organizationID = fixture.organization.id!
            let nested = try await builder.createOU(
                name: "Folder Nested", description: "d", organization: fixture.organization,
                parentOU: fixture.folder)

            func folderNames(_ path: String, token: String) async throws -> [String] {
                var names: [String] = []
                try await app.test(.GET, path) { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                } afterResponse: { res in
                    #expect(res.status == .ok, "\(path) -> \(res.status): \(res.body.string)")
                    names = try res.content.decode([OrganizationalUnitResponse].self).map(\.name)
                }
                return names
            }

            let topLevel = "/api/organizations/\(organizationID)/ous"
            let children = "\(topLevel)/\(fixture.folder.id!)/ous"

            // The folder structure is part of what the project inventory
            // disclosed, and it has its own door.
            #expect(try await folderNames(topLevel, token: fixture.token).isEmpty)
            #expect(try await folderNames(children, token: fixture.token).isEmpty)

            let admin = try await builder.createUser(
                username: "folder-admin", email: "folder-admin@example.com")
            try await builder.addUserToOrganization(
                user: admin, organization: fixture.organization, role: "admin")
            let adminToken = try await admin.generateAPIKey(on: app.db)

            #expect(try await folderNames(topLevel, token: adminToken) == ["Folder Folder"])
            #expect(try await folderNames(children, token: adminToken) == [nested.name])
        }
    }

    @Test("The quota list decides each row on the scope it hangs on")
    func quotaListIsScopedToTheCaller() async throws {
        try await withApp { app in
            let fixture = try await makeFixture(app, prefix: "Quota")

            let projectQuota = ResourceQuota(
                name: "Quota Project Limit",
                organizationID: nil,
                organizationalUnitID: nil,
                projectID: fixture.rootProject.id,
                maxVCPUs: 10,
                maxMemory: 10 * 1024 * 1024 * 1024,
                maxStorage: 100 * 1024 * 1024 * 1024,
                maxVMs: 5
            )
            try await projectQuota.save(on: app.db)

            func quotaNames(_ path: String) async throws -> [String] {
                var names: [String] = []
                try await app.test(.GET, path) { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                } afterResponse: { res in
                    #expect(res.status == .ok, "\(path) -> \(res.status): \(res.body.string)")
                    names = try res.content.decode(PagedResponse<ResourceQuotaResponse>.self).items.map(\.name)
                }
                return names
            }

            #expect(try await quotaNames("/api/quotas?level=project").isEmpty)
            #expect(try await quotaNames("/api/quotas").isEmpty)

            try await RoleBindingService.grant(
                principalType: .user, principalID: fixture.member.id!, role: .viewer,
                nodeType: .project, nodeID: fixture.rootProject.id!, createdBy: nil, on: app.db)

            #expect(try await quotaNames("/api/quotas?level=project") == ["Quota Project Limit"])
            #expect(try await quotaNames("/api/quotas") == ["Quota Project Limit"])
        }
    }

    /// The reverse of the leak this file exists for, in the endpoint most at
    /// risk of it: narrowing on membership rows rather than on grants hides a
    /// row the evaluator allows. A project binding is a complete grant on its
    /// own — no `user_organizations` row is implied by it or required for it.
    @Test("A project grant with no organization membership row still reaches its quota")
    func quotaListDoesNotRequireAnOrganizationMembershipRow() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let organization = try await builder.createOrganization(name: "Unaffiliated Org")
            let project = try await builder.createProject(
                name: "Unaffiliated Project", description: "d", organization: organization)
            let quota = ResourceQuota(
                name: "Unaffiliated Limit",
                projectID: project.id,
                maxVCPUs: 4,
                maxMemory: 4 * 1024 * 1024 * 1024,
                maxStorage: 40 * 1024 * 1024 * 1024,
                maxVMs: 2
            )
            try await quota.save(on: app.db)

            // Deliberately no `addUserToOrganization`.
            let outsider = try await builder.createUser(
                username: "unaffiliated", email: "unaffiliated@example.com")
            try await RoleBindingService.grant(
                principalType: .user, principalID: outsider.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)
            let token = try await outsider.generateAPIKey(on: app.db)

            // `GET /api/projects` still bounds its candidate set by membership
            // rows (#879), so it does not yet answer this caller — tracked
            // separately; the point here is that the quota list no longer
            // decides anything with that bound.
            for path in ["/api/quotas", "/api/quotas?level=project"] {
                try await app.test(.GET, path) { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                } afterResponse: { res in
                    #expect(res.status == .ok, "\(path) -> \(res.status): \(res.body.string)")
                    let names = try res.content.decode(PagedResponse<ResourceQuotaResponse>.self).items.map(\.name)
                    #expect(names == ["Unaffiliated Limit"], "\(path) returned \(names)")
                }
            }
        }
    }

    /// The unnarrowed path — a system admin holds no bindings, so
    /// `ProjectVisibility` derives no bound and every row reaches the evaluator.
    /// The bare-member fixture above can never enter this branch.
    @Test("A system admin sees quotas in organizations they hold no membership row in")
    func quotaListIsUnnarrowedForSystemAdmins() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let organization = try await builder.createOrganization(name: "Admin Quota Org")
            let project = try await builder.createProject(
                name: "Admin Quota Project", description: "d", organization: organization)
            let quota = ResourceQuota(
                name: "Admin Quota Limit",
                projectID: project.id,
                maxVCPUs: 8,
                maxMemory: 8 * 1024 * 1024 * 1024,
                maxStorage: 80 * 1024 * 1024 * 1024,
                maxVMs: 4
            )
            try await quota.save(on: app.db)

            let admin = try await builder.createUser(
                username: "quota-admin", email: "quota-admin@example.com", isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app.db)

            try await app.test(.GET, "/api/quotas") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.status): \(res.body.string)")
                let names = try res.content.decode(PagedResponse<ResourceQuotaResponse>.self).items.map(\.name)
                #expect(names == ["Admin Quota Limit"])
            }
        }
    }

    @Test("The flat resource list carries no folder the caller has not been decided on")
    func flatResourceListOmitsConnectivityAncestors() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let organization = try await builder.createOrganization(name: "Ancestor Org")
            let outer = try await builder.createOU(
                name: "Ancestor Outer", description: "secret roadmap", organization: organization)
            let inner = try await builder.createOU(
                name: "Ancestor Inner", description: "secret team", organization: organization,
                parentOU: outer)
            let project = try await builder.createProject(
                name: "Ancestor Project", description: "d", ou: inner)

            let member = try await builder.createUser(
                username: "ancestor-member", email: "ancestor@example.com")
            try await builder.addUserToOrganization(
                user: member, organization: organization, role: "member")
            try await RoleBindingService.grant(
                principalType: .user, principalID: member.id!, role: .viewer,
                nodeType: .project, nodeID: project.id!, createdBy: nil, on: app.db)
            let token = try await member.generateAPIKey(on: app.db)

            try await app.test(.GET, "/api/organizations/\(organization.id!)/resources") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.status): \(res.body.string)")
                let resources = try res.content.decode(OrganizationResourcesResponse.self)
                #expect(resources.projects.map(\.name) == ["Ancestor Project"])
                // `folder:read` was never granted on either enclosing folder,
                // and a flat array has no nesting to justify carrying them.
                #expect(resources.organizationalUnits.isEmpty)
                #expect(resources.summary.totalOUs == 0)
            }

            // The tree still nests the project under both, so it keeps them.
            try await app.test(.GET, "/api/organizations/\(organization.id!)/hierarchy") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.status): \(res.body.string)")
                let tree = try res.content.decode(OrganizationHierarchyResponse.self)
                let top = tree.organization.organizationalUnits
                #expect(top.map(\.name) == [outer.name])
                #expect(top.first?.childOUs.map(\.name) == [inner.name])
                #expect(top.first?.childOUs.first?.projects.map(\.name) == ["Ancestor Project"])
                // Counted as zero: the two folders are scaffolding for the
                // nesting, not folders this caller was allowed.
                #expect(tree.stats.totalOUs == 0)
            }
        }
    }
}
