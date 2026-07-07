import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// Regression tests for the SpiceDB org-membership mirroring bugs: `removeMember`
/// left the SpiceDB tuple behind (removed user kept access) and `updateMemberRole`
/// wrote the new role without deleting the old one (a demoted admin kept admin
/// permissions). These drive the endpoints through the full stack against the mock
/// SpiceDB and assert on the writes AND deletes the mock received via
/// `SpiceDBMockRecorder`.
@Suite("Org Member SpiceDB Mirror Tests", .serialized)
final class OrgMemberSpiceDBMirrorTests {

    /// Boots a configured test app with an acting org admin, a second target member,
    /// and a recorder installed so the test can assert on relationship writes/deletes.
    /// The recorder is installed AFTER the fixture data is built (which writes only to
    /// the DB, not SpiceDB), so only the endpoint under test contributes records.
    private func withOrgTestApp(
        targetRole: String,
        _ test: (Application, Organization, User, User, String, SpiceDBMockRecorder) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Mirror Org")

            let admin = try await builder.createUser(
                username: "mirroradmin",
                email: "mirroradmin@example.com",
                displayName: "Mirror Admin",
                isSystemAdmin: false
            )
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            admin.currentOrganizationId = org.id
            try await admin.save(on: app.db)

            let target = try await builder.createUser(
                username: "mirrortarget",
                email: "mirrortarget@example.com",
                displayName: "Mirror Target",
                isSystemAdmin: false
            )
            try await builder.addUserToOrganization(user: target, organization: org, role: targetRole)

            let adminToken = try await admin.generateAPIKey(on: app.db)

            let recorder = SpiceDBMockRecorder()
            app.spicedbMockRecorder = recorder

            try await test(app, org, admin, target, adminToken, recorder)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    @Test("Demoting admin→member deletes the old tuple and writes the new one")
    func updateRoleDeletesOldTuple() async throws {
        // Target starts as a second admin so the "cannot demote the last admin" guard
        // does not fire.
        try await withOrgTestApp(targetRole: "admin") { app, org, _, target, adminToken, recorder in
            try await app.test(
                .PATCH,
                "/api/organizations/\(org.id!)/members/\(target.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(["role": "member"])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let deletes = await recorder.deletes
            let writes = await recorder.writes
            let orgId = org.id!.uuidString
            let targetId = target.id!.uuidString

            let deletedOldRole = deletes.contains(
                SpiceDBMockRecorder.RelationshipWrite(
                    entity: "organization",
                    entityId: orgId,
                    relation: "admin",
                    subject: "user",
                    subjectId: targetId
                )
            )
            let wroteNewRole = writes.contains(
                SpiceDBMockRecorder.RelationshipWrite(
                    entity: "organization",
                    entityId: orgId,
                    relation: "member",
                    subject: "user",
                    subjectId: targetId
                )
            )
            #expect(deletedOldRole)
            #expect(wroteNewRole)
        }
    }

    @Test("Removing a member deletes the SpiceDB tuple")
    func removeMemberDeletesTuple() async throws {
        try await withOrgTestApp(targetRole: "member") { app, org, _, target, adminToken, recorder in
            try await app.test(
                .DELETE,
                "/api/organizations/\(org.id!)/members/\(target.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let deletes = await recorder.deletes
            let orgId = org.id!.uuidString
            let targetId = target.id!.uuidString

            let deletedMemberTuple = deletes.contains(
                SpiceDBMockRecorder.RelationshipWrite(
                    entity: "organization",
                    entityId: orgId,
                    relation: "member",
                    subject: "user",
                    subjectId: targetId
                )
            )
            #expect(deletedMemberTuple)
        }
    }

    @Test("Re-setting the same role records no delete")
    func unchangedRoleRecordsNoDelete() async throws {
        try await withOrgTestApp(targetRole: "member") { app, org, _, target, adminToken, recorder in
            try await app.test(
                .PATCH,
                "/api/organizations/\(org.id!)/members/\(target.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(["role": "member"])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let deletes = await recorder.deletes
            #expect(deletes.isEmpty)
        }
    }
}
