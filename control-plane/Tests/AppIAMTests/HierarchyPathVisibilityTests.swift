import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// The two doors onto an organization's inventory that the per-row filtering of
/// issue #870 left open.
///
/// Both sit on endpoints that #870 otherwise fixed, which is what makes them
/// easy to miss: `GET /api/organizations/:id/path/...` was not touched at all,
/// and `/resources/summary` narrowed `resourceUsage` per row while handing the
/// same organization-wide totals straight back through `quotaCompliance`.
@Suite("Hierarchy Path and Quota Usage Visibility", .serialized)
final class HierarchyPathVisibilityTests {

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
        let organization: Organization
        let folder: OrganizationalUnit
        let nestedProject: Project
        let directProject: Project
        let nestedVM: VM
        let directVM: VM
    }

    private func makeFixture(_ builder: TestDataBuilder) async throws -> Fixture {
        let organization = try await builder.createOrganization(name: "Path Org")
        let folder = try await builder.createOU(
            name: "Engineering", description: "d", organization: organization)
        let nestedProject = try await builder.createProject(
            name: "Nested Project", description: "d", ou: folder)
        let directProject = try await builder.createProject(
            name: "Direct Project", description: "d", organization: organization)
        let nestedVM = try await builder.createVM(name: "nested-vm", project: nestedProject)
        let directVM = try await builder.createVM(name: "direct-vm", project: directProject)

        // One quota at each scope: the folder-scoped row is the branch where the
        // node the read is decided on diverges most from the row's own naming,
        // and where `readable(on:)` applies a different action (`folder:read`)
        // to the same row.
        _ = try await builder.createResourceQuota(name: "org-quota", organization: organization)
        _ = try await builder.createResourceQuota(name: "folder-quota", ou: folder)
        _ = try await builder.createResourceQuota(name: "project-quota", project: directProject)

        return Fixture(
            organization: organization,
            folder: folder,
            nestedProject: nestedProject,
            directProject: directProject,
            nestedVM: nestedVM,
            directVM: directVM
        )
    }

    /// A member of the organization holding no binding of their own — the caller
    /// the "membership grants `org:read` and `project:create`, nothing else"
    /// invariant is about.
    private func bareMember(
        _ app: Application, builder: TestDataBuilder, organization: Organization, username: String
    ) async throws -> (User, String) {
        let user = try await builder.createUser(username: username, email: "\(username)@example.com")
        try await builder.addUserToOrganization(user: user, organization: organization, role: "member")
        return (user, try await user.generateAPIKey(on: app.db))
    }

    private func grantViewer(_ app: Application, to user: User, on node: IAMNode) async throws {
        try await RoleBindingService.grant(
            principalType: .user, principalID: user.id!, role: .viewer,
            nodeType: node.type, nodeID: node.id, createdBy: nil, on: app.db)
    }

    private func entityPath(
        _ app: Application, organization: Organization, type: String, id: UUID, token: String
    ) async throws -> [App.PathComponent] {
        var decoded: EntityPathResponse?
        try await app.test(.GET, "/api/organizations/\(organization.id!)/path/\(type)/\(id)") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
        } afterResponse: { res in
            #expect(res.status == .ok, "\(res.status): \(res.body.string)")
            decoded = try res.content.decode(EntityPathResponse.self)
        }
        return try #require(decoded).pathComponents
    }

    private func summary(
        _ app: Application, organization: Organization, token: String
    ) async throws -> ResourceSummaryResponse {
        var decoded: ResourceSummaryResponse?
        try await app.test(.GET, "/api/organizations/\(organization.id!)/resources/summary") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
        } afterResponse: { res in
            #expect(res.status == .ok, "\(res.status): \(res.body.string)")
            decoded = try res.content.decode(ResourceSummaryResponse.self)
        }
        return try #require(decoded)
    }

    // MARK: - Breadcrumb paths

    @Test("A breadcrumb names nothing a bare member may not read")
    func entityPathIsBareForABareMember() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let fixture = try await makeFixture(builder)
            let (_, token) = try await bareMember(
                app, builder: builder, organization: fixture.organization, username: "path-bare")

            // Resolving an arbitrary VM id used to return organization → folder →
            // project → VM by name, on nothing more than `view_organization`.
            let vmPath = try await entityPath(
                app, organization: fixture.organization, type: "vm", id: fixture.nestedVM.id!, token: token)
            #expect(vmPath.map(\.type) == ["organization"])

            let folderPath = try await entityPath(
                app, organization: fixture.organization, type: "ou", id: fixture.folder.id!, token: token)
            #expect(folderPath.map(\.type) == ["organization"])
        }
    }

    @Test("A breadcrumb elides the folders the caller may not read")
    func entityPathElidesUnreadableAncestors() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let fixture = try await makeFixture(builder)
            let (user, token) = try await bareMember(
                app, builder: builder, organization: fixture.organization, username: "path-scoped")
            // A grant on the project alone never implies `folder:read` on the
            // folder holding it.
            try await grantViewer(app, to: user, on: IAMNode(type: .project, id: fixture.nestedProject.id!))

            let components = try await entityPath(
                app, organization: fixture.organization, type: "project",
                id: fixture.nestedProject.id!, token: token)

            #expect(components.map(\.type) == ["organization", "project"])
            #expect(components.map(\.name) == ["Path Org", "Nested Project"])
        }
    }

    @Test("An org admin still gets the whole breadcrumb")
    func entityPathIsCompleteForAnAdmin() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let fixture = try await makeFixture(builder)
            let admin = try await builder.createUser(username: "path-admin", email: "path-admin@example.com")
            try await builder.addUserToOrganization(
                user: admin, organization: fixture.organization, role: "admin")
            let token = try await admin.generateAPIKey(on: app.db)

            let components = try await entityPath(
                app, organization: fixture.organization, type: "vm", id: fixture.nestedVM.id!, token: token)

            #expect(components.map(\.type) == ["organization", "organizational_unit", "project", "vm"])
            #expect(components.map(\.name) == ["Path Org", "Engineering", "Nested Project", "nested-vm"])
        }
    }

    // MARK: - Quota compliance

    @Test("A bare member is told no quota's measured usage")
    func quotaComplianceIsEmptyForABareMember() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let fixture = try await makeFixture(builder)
            let (_, token) = try await bareMember(
                app, builder: builder, organization: fixture.organization, username: "quota-bare")

            let response = try await summary(app, organization: fixture.organization, token: token)

            // `resourceUsage` was already narrowed to this caller's rows...
            #expect(response.resourceUsage.totalVMs == 0)
            // ...and the organization-scoped quota must not report the same
            // organization-wide figures back through the other field.
            #expect(response.quotaCompliance.isEmpty)
        }
    }

    @Test("A project binding is told that project's usage, not the organization's")
    func quotaComplianceIsScopedToTheCallersGrant() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let fixture = try await makeFixture(builder)
            let (user, token) = try await bareMember(
                app, builder: builder, organization: fixture.organization, username: "quota-scoped")
            try await grantViewer(app, to: user, on: IAMNode(type: .project, id: fixture.directProject.id!))

            let response = try await summary(app, organization: fixture.organization, token: token)

            #expect(response.quotaCompliance.map(\.quotaName) == ["project-quota"])
            // Two VMs of 2 vCPUs each exist in the organization; this caller may
            // see one. Were the org-scoped quota reported, its `used` would
            // read 4 vCPUs across 2 VMs.
            let projectQuota = try #require(response.quotaCompliance.first)
            #expect(projectQuota.cpuCompliance.used == 2)
            #expect(projectQuota.vmCompliance.used == 1)
        }
    }

    @Test("An org admin still sees the organization's quota compliance")
    func quotaComplianceIsCompleteForAnAdmin() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let fixture = try await makeFixture(builder)
            let admin = try await builder.createUser(username: "quota-admin", email: "quota-admin@example.com")
            try await builder.addUserToOrganization(
                user: admin, organization: fixture.organization, role: "admin")
            let token = try await admin.generateAPIKey(on: app.db)

            let response = try await summary(app, organization: fixture.organization, token: token)

            #expect(
                Set(response.quotaCompliance.map(\.quotaName)) == ["org-quota", "folder-quota", "project-quota"])
            let orgQuota = try #require(response.quotaCompliance.first { $0.quotaName == "org-quota" })
            #expect(orgQuota.cpuCompliance.used == 4)
            #expect(orgQuota.vmCompliance.used == 2)
        }
    }

    /// The folder branch of `QuotaVisibility.measuredNode`: a folder-scoped
    /// quota measures the folder's whole subtree, so a folder grant is what
    /// reaches it — and an unrelated project grant is not.
    @Test("A folder-scoped quota follows the folder grant, not a sibling project's")
    func folderScopedQuotaFollowsTheFolderGrant() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let fixture = try await makeFixture(builder)

            let folderViewer = try await builder.createUser(
                username: "quota-folder", email: "quota-folder@example.com")
            try await builder.addUserToOrganization(
                user: folderViewer, organization: fixture.organization, role: "member")
            try await grantViewer(
                app, to: folderViewer, on: IAMNode(type: .organizationalUnit, id: fixture.folder.id!))
            let folderToken = try await folderViewer.generateAPIKey(on: app.db)

            // A folder grant reaches the folder's own quota and the quota of the
            // project nested under it, and stops there.
            let folderView = try await summary(app, organization: fixture.organization, token: folderToken)
            #expect(folderView.quotaCompliance.map(\.quotaName) == ["folder-quota"])
            let folderQuota = try #require(folderView.quotaCompliance.first)
            #expect(folderQuota.vmCompliance.used == 1)

            // The caller granted only the org-parented project sees neither the
            // folder's quota nor the folder subtree's usage.
            let (projectViewer, projectToken) = try await bareMember(
                app, builder: builder, organization: fixture.organization, username: "quota-sibling")
            try await grantViewer(
                app, to: projectViewer, on: IAMNode(type: .project, id: fixture.directProject.id!))
            let projectView = try await summary(app, organization: fixture.organization, token: projectToken)
            #expect(projectView.quotaCompliance.map(\.quotaName) == ["project-quota"])
        }
    }

    // MARK: - The other doors onto the same number

    /// `ResourceQuotaResponse` ships `usage`/`utilization` off the stored
    /// counters, which `QuotaEnforcementService.resyncReservations` writes
    /// straight from `QuotaUsageAggregator.measure` — the same quantity
    /// `quotaCompliance` reports. Gating one field would only move the number,
    /// so every route carrying the row asks the same question.
    @Test("A bare member reaches the organization's measured usage on no route")
    func measuredUsageIsUnreachableForABareMember() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let fixture = try await makeFixture(builder)
            let (_, token) = try await bareMember(
                app, builder: builder, organization: fixture.organization, username: "usage-bare")

            let orgQuota = try #require(
                try await ResourceQuota.query(on: app.db).filter(\.$name == "org-quota").first())
            let quotaID = try orgQuota.requireID()

            // The direct door: measured live, with a per-VM breakdown.
            try await app.test(.GET, "/api/quotas/\(quotaID)/usage") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden, "\(res.status): \(res.body.string)")
            }

            try await app.test(.GET, "/api/quotas/\(quotaID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden, "\(res.status): \(res.body.string)")
            }

            // And the rows that carry the counters.
            try await app.test(.GET, "/api/quotas") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.status): \(res.body.string)")
                let quotas = try res.content.decode(PagedResponse<ResourceQuotaResponse>.self)
                #expect(quotas.items.isEmpty)
            }

            for path in ["hierarchy", "resources"] {
                try await app.test(.GET, "/api/organizations/\(fixture.organization.id!)/\(path)") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                } afterResponse: { res in
                    #expect(res.status == .ok, "\(res.status): \(res.body.string)")
                    #expect(!res.body.string.contains("org-quota"), "\(path) still carries the org quota row")
                }
            }
        }
    }

    @Test("An org admin still reaches a quota's measured usage")
    func measuredUsageStaysAvailableToAnAdmin() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let fixture = try await makeFixture(builder)
            let admin = try await builder.createUser(username: "usage-admin", email: "usage-admin@example.com")
            try await builder.addUserToOrganization(
                user: admin, organization: fixture.organization, role: "admin")
            let token = try await admin.generateAPIKey(on: app.db)

            let orgQuota = try #require(
                try await ResourceQuota.query(on: app.db).filter(\.$name == "org-quota").first())

            try await app.test(.GET, "/api/quotas/\(try orgQuota.requireID())/usage") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.status): \(res.body.string)")
            }
        }
    }
}
