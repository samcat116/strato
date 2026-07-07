import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// Tests project-level role grants (users and groups): the relational mirror rows are
/// written, the SpiceDB tuples are recorded (including delete-old-then-write-new on a
/// role change), and listing/mutations are gated by view_project / manage_project.
@Suite("Project Member Tests", .serialized)
final class ProjectMemberTests {

    private func withApp(
        _ test: (Application, Project, User, User, Group, String, SpiceDBMockRecorder) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "PM Org")
            let actor = try await builder.createUser(
                username: "pmactor", email: "pmactor@example.com", displayName: "PM Actor")
            try await builder.addUserToOrganization(user: actor, organization: org, role: "admin")
            actor.currentOrganizationId = org.id
            try await actor.save(on: app.db)

            let target = try await builder.createUser(
                username: "pmtarget", email: "pmtarget@example.com", displayName: "PM Target")

            let project = try await builder.createProject(
                name: "PM Project", description: "d", organization: org)

            let group = Group(name: "PM Group", description: "d", organizationID: org.id!)
            try await group.save(on: app.db)

            let token = try await actor.generateAPIKey(on: app.db)

            let recorder = SpiceDBMockRecorder()
            app.spicedbMockRecorder = recorder

            try await test(app, project, actor, target, group, token, recorder)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("Granting a user role writes a row and a SpiceDB tuple")
    func grantWritesRowAndTuple() async throws {
        try await withApp { app, project, _, target, _, token, recorder in
            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: "member"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let count = try await ProjectMember.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .filter(\.$user.$id == target.id!)
                .count()
            #expect(count == 1)

            let writes = await recorder.writes
            let wroteTuple = writes.contains(
                SpiceDBMockRecorder.RelationshipWrite(
                    entity: "project", entityId: project.id!.uuidString,
                    relation: "member", subject: "user", subjectId: target.id!.uuidString))
            #expect(wroteTuple)
        }
    }

    @Test("Changing a role records delete-old + write-new")
    func roleChangeRecordsDeleteAndWrite() async throws {
        try await withApp { app, project, _, target, _, token, recorder in
            // Seed a member grant directly, then PATCH to admin.
            try await ProjectMember(projectID: project.id!, userID: target.id!, role: "member")
                .save(on: app.db)

            try await app.test(.PATCH, "/api/projects/\(project.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ProjectMemberController.UpdateMemberRoleRequest(role: "admin"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let deletes = await recorder.deletes
            let writes = await recorder.writes
            let deletedOld = deletes.contains(
                SpiceDBMockRecorder.RelationshipWrite(
                    entity: "project", entityId: project.id!.uuidString,
                    relation: "member", subject: "user", subjectId: target.id!.uuidString))
            let wroteNew = writes.contains(
                SpiceDBMockRecorder.RelationshipWrite(
                    entity: "project", entityId: project.id!.uuidString,
                    relation: "admin", subject: "user", subjectId: target.id!.uuidString))
            #expect(deletedOld)
            #expect(wroteNew)
        }
    }

    @Test("Revoking removes the row and records a delete")
    func revokeRemovesRowAndTuple() async throws {
        try await withApp { app, project, _, target, _, token, recorder in
            try await ProjectMember(projectID: project.id!, userID: target.id!, role: "viewer")
                .save(on: app.db)

            try await app.test(.DELETE, "/api/projects/\(project.id!)/members/\(target.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let count = try await ProjectMember.query(on: app.db)
                .filter(\.$project.$id == project.id!)
                .filter(\.$user.$id == target.id!)
                .count()
            #expect(count == 0)

            let deletes = await recorder.deletes
            let deleted = deletes.contains(
                SpiceDBMockRecorder.RelationshipWrite(
                    entity: "project", entityId: project.id!.uuidString,
                    relation: "viewer", subject: "user", subjectId: target.id!.uuidString))
            #expect(deleted)
        }
    }

    @Test("Granting a group writes a group tuple")
    func grantGroupWritesTuple() async throws {
        try await withApp { app, project, _, _, group, token, recorder in
            try await app.test(.POST, "/api/projects/\(project.id!)/groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantGroupRequest(groupID: group.id!, role: "member"))
            } afterResponse: { res in
                #expect(res.status == .created)
            }

            let writes = await recorder.writes
            let wrote = writes.contains(
                SpiceDBMockRecorder.RelationshipWrite(
                    entity: "project", entityId: project.id!.uuidString,
                    relation: "group_member", subject: "group", subjectId: group.id!.uuidString))
            #expect(wrote)
        }
    }

    @Test("Listing requires view_project")
    func listRequiresViewProject() async throws {
        try await withApp { app, project, _, _, _, token, _ in
            app.spicedbMockDeniedResources = ["project"]
            try await app.test(.GET, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Granting requires manage_project")
    func grantRequiresManageProject() async throws {
        try await withApp { app, project, _, target, _, token, _ in
            app.spicedbMockDeniedResources = ["project"]
            try await app.test(.POST, "/api/projects/\(project.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    ProjectMemberController.GrantMemberRequest(
                        userEmail: target.email, userID: nil, role: "member"))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }
}
