import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// Covers the materialized-path prefix matching that replaced the folder-tree
/// walk and the unindexable `LIKE '%<uuid>%'` descendant lookup (issue #692).
@Suite("Folder Subtree Tests", .serialized)
struct FolderSubtreeTests {

    /// Boots an app with an admin user (bearer token) and an organization.
    private func withOrgApp(
        _ test: (Application, Organization, TestDataBuilder, String) async throws -> Void
    ) async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "folderadmin", email: "folders@example.com")
            let org = try await builder.createOrganization(name: "Folder Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, org, builder, token)
        }
    }

    @Test("descendants spans the whole subtree and excludes siblings")
    func descendantsSpanSubtree() async throws {
        try await withOrgApp { app, org, builder, _ in
            let engineering = try await builder.createOU(
                name: "Engineering", description: "d", organization: org)
            let teamA = try await builder.createOU(
                name: "TeamA", description: "d", organization: org, parentOU: engineering)
            let squad = try await builder.createOU(
                name: "Squad", description: "d", organization: org, parentOU: teamA)
            let marketing = try await builder.createOU(
                name: "Marketing", description: "d", organization: org)

            let descendantIDs = Set(try await engineering.descendants(on: app.db).compactMap { $0.id })
            #expect(descendantIDs == Set([teamA.id!, squad.id!]))
            #expect(!descendantIDs.contains(engineering.id!))
            #expect(!descendantIDs.contains(marketing.id!))

            let subtree = Set(try await engineering.selfAndDescendantIDs(on: app.db))
            #expect(subtree == Set([engineering.id!, teamA.id!, squad.id!]))

            // A leaf has no descendants but is still its own subtree.
            let leafDescendants = try await squad.descendants(on: app.db)
            let leafSubtree = try await squad.selfAndDescendantIDs(on: app.db)
            #expect(leafDescendants.isEmpty)
            #expect(leafSubtree == [squad.id!])
        }
    }

    @Test("Moving a folder rewrites the paths of everything beneath it")
    func moveRewritesDescendantPaths() async throws {
        try await withOrgApp { app, org, builder, token in
            let engineering = try await builder.createOU(
                name: "Engineering", description: "d", organization: org)
            let teamA = try await builder.createOU(
                name: "TeamA", description: "d", organization: org, parentOU: engineering)
            let squad = try await builder.createOU(
                name: "Squad", description: "d", organization: org, parentOU: teamA)
            let platform = try await builder.createOU(
                name: "Platform", description: "d", organization: org)

            // Move TeamA (with its child) from Engineering to Platform. The
            // descendants are found by the path TeamA carried *before* the
            // move — their own paths still extend the old one at that point.
            try await app.test(.POST, "/api/organizations/\(org.id!)/ous/\(teamA.id!)/move") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(MoveOrganizationalUnitRequest(newParentOuId: platform.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let movedTeam = try #require(try await OrganizationalUnit.find(teamA.id, on: app.db))
            let movedSquad = try #require(try await OrganizationalUnit.find(squad.id, on: app.db))
            #expect(movedTeam.path == "/\(org.id!.uuidString)/\(platform.id!.uuidString)/\(teamA.id!.uuidString)")
            #expect(movedSquad.path == "\(movedTeam.path)/\(squad.id!.uuidString)")
            #expect(movedSquad.depth == 2)

            // And the subtree is discoverable from its new parent.
            let platformSubtree = Set(try await platform.descendants(on: app.db).compactMap { $0.id })
            let engineeringSubtree = try await engineering.descendants(on: app.db)
            #expect(platformSubtree == Set([teamA.id!, squad.id!]))
            #expect(engineeringSubtree.isEmpty)
        }
    }

    @Test("A folder quota measures workloads moved into its subtree")
    func folderQuotaFollowsMovedSubtree() async throws {
        try await withOrgApp { app, org, builder, token in
            let engineering = try await builder.createOU(
                name: "Engineering", description: "d", organization: org)
            let platform = try await builder.createOU(
                name: "Platform", description: "d", organization: org)
            let teamA = try await builder.createOU(
                name: "TeamA", description: "d", organization: org, parentOU: engineering)
            let project = try await builder.createProject(name: "App", description: "p", ou: teamA)
            _ = try await builder.createVM(name: "one", project: project)  // cpu 2

            let platformQuota = try await builder.createResourceQuota(name: "platform", ou: platform)
            let before = try await QuotaUsageAggregator.measure(quota: platformQuota, on: app.db)
            #expect(before.vmCount == 0)

            try await app.test(.POST, "/api/organizations/\(org.id!)/ous/\(teamA.id!)/move") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(MoveOrganizationalUnitRequest(newParentOuId: platform.id))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let after = try await QuotaUsageAggregator.measure(quota: platformQuota, on: app.db)
            #expect(after.vmCount == 1)
            #expect(after.vcpus == 2)
        }
    }
}
