import Fluent
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

@Suite("Volume Snapshot List Tests", .serialized)
struct VolumeSnapshotListTests {
    @Test("Project snapshot collection is scoped and paged")
    func projectCollectionIsScopedAndPaged() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "snapshot-list-admin",
                email: "snapshot-list-admin@example.com",
                isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app.db)
            let organization = try await builder.createOrganization(name: "Snapshot List Org")
            try await builder.addUserToOrganization(
                user: admin, organization: organization, role: "admin")
            let project = try await builder.createProject(
                name: "Snapshot List Project", description: "", organization: organization)
            let otherProject = try await builder.createProject(
                name: "Other Snapshot Project", description: "", organization: organization)

            func createSnapshot(named name: String, in project: Project) async throws {
                let volume = Volume(
                    name: "\(name)-volume", description: "", projectID: project.id!,
                    environment: "development", size: 1 << 30, status: .available,
                    createdByID: admin.id!)
                try await volume.save(on: app.db)
                let snapshot = VolumeSnapshot(
                    name: name, description: "", volumeID: volume.id!, projectID: project.id!,
                    environment: "development", size: volume.size, createdByID: admin.id!)
                try await snapshot.save(on: app.db)
            }

            try await createSnapshot(named: "first", in: project)
            try await createSnapshot(named: "second", in: project)
            try await createSnapshot(named: "foreign", in: otherProject)

            try await app.test(
                .GET,
                "/api/volume-snapshots?project_id=\(project.id!)&limit=1&offset=1"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { response in
                #expect(response.status == .ok)
                let page = try response.content.decode(PagedResponse<SnapshotResponse>.self)
                #expect(page.total == 2)
                #expect(page.limit == 1)
                #expect(page.offset == 1)
                #expect(page.items.count == 1)
                #expect(page.items[0].projectId == project.id)
            }
        }
    }

    @Test("Project id is required")
    func projectIdIsRequired() async throws {
        try await withTestApp { app in
            let admin = try await TestDataBuilder(db: app.db).createUser(
                username: "snapshot-list-required",
                email: "snapshot-list-required@example.com",
                isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app.db)

            try await app.test(.GET, "/api/volume-snapshots") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { response in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("project_id"))
            }
        }
    }

    @Test("Project snapshot collection filters volumes the credential cannot read")
    func projectCollectionFiltersUnreadableVolumes() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "snapshot-list-restricted",
                email: "snapshot-list-restricted@example.com",
                isSystemAdmin: true)
            let projectOnly = try CredentialRestriction.validated(
                actions: ["project:read"], nodeType: nil, nodeID: nil)
            let token = try await admin.generateAPIKey(
                on: app.db, restriction: projectOnly)
            let organization = try await builder.createOrganization(
                name: "Restricted Snapshot List Org")
            let project = try await builder.createProject(
                name: "Restricted Snapshot List Project", description: "",
                organization: organization)
            let volume = Volume(
                name: "hidden-volume", description: "", projectID: project.id!,
                environment: "development", size: 1 << 30, status: .available,
                createdByID: admin.id!)
            try await volume.save(on: app.db)
            try await VolumeSnapshot(
                name: "hidden-snapshot", description: "", volumeID: volume.id!,
                projectID: project.id!, environment: "development", size: volume.size,
                createdByID: admin.id!
            ).save(on: app.db)

            try await app.test(
                .GET,
                "/api/volume-snapshots?project_id=\(project.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { response in
                #expect(response.status == .ok)
                let page = try response.content.decode(PagedResponse<SnapshotResponse>.self)
                #expect(page.total == 0)
                #expect(page.items.isEmpty)
            }
        }
    }
}
