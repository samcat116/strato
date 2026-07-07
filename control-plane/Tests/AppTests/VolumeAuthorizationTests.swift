import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// Regression tests for the Codex finding on PR #293: `createVolume` accepted
/// `sourceImageId` after checking only that the image exists and is ready, never
/// asking SpiceDB whether the caller can read it. A user could therefore create a
/// volume from another project's image and have `provisionVolume` sign a download
/// URL for it. These tests pin the fix: image read is withheld while project
/// `create_volume` is still granted, and the request must fail with 403.
@Suite("Volume Authorization Tests", .serialized)
final class VolumeAuthorizationTests {

    /// Boots a configured test app with a non-admin user, org, project, and a
    /// ready image in that project.
    private func withVolumeTestApp(
        _ test: (Application, Project, Image, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "volauthuser",
                email: "volauth@example.com",
                displayName: "Volume Auth User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Volume Auth Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Volume Auth Project",
                description: "Project for volume authorization tests",
                organization: org
            )
            let image = try await builder.createImage(
                name: "volume-source-image",
                project: project,
                status: .ready,
                uploadedBy: user
            )
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, project, image, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    private func createVolumeBody(project: Project, image: Image) -> CreateVolumeRequest {
        CreateVolumeRequest(
            name: "vol-from-image",
            description: "volume sourced from an image",
            projectId: project.id!,
            sizeGB: 10,
            format: "qcow2",
            volumeType: "boot",
            sourceImageId: image.id!
        )
    }

    @Test("POST /api/volumes with a sourceImageId the user cannot read is denied (403)")
    func createFromImageDeniedWithoutImagePermission() async throws {
        try await withVolumeTestApp { app, project, image, token in
            // Grant everything except image reads: the project-level
            // `create_volume` check passes, so a 403 can only come from the
            // image permission check.
            app.spicedbMockAllows = true
            app.spicedbMockDeniedResources = ["image"]

            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(self.createVolumeBody(project: project, image: image))
            } afterResponse: { res in
                // Before the fix this returned 200 and kicked off provisioning,
                // which signs a download URL for an image the caller can't read.
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("Access denied to image"))
            }

            // The unauthorized request must not have left a volume behind.
            let volumeCount = try await Volume.query(on: app.db).count()
            #expect(volumeCount == 0)
        }
    }

    @Test("POST /api/volumes with a readable sourceImageId succeeds (200)")
    func createFromImageAllowedWithPermission() async throws {
        try await withVolumeTestApp { app, project, image, token in
            app.spicedbMockAllows = true
            app.spicedbMockDeniedResources = []

            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(self.createVolumeBody(project: project, image: image))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let volume = try res.content.decode(VolumeResponse.self)
                #expect(volume.sourceImageId == image.id)
            }

            // createVolume provisions on a detached task that touches app.db;
            // wait for it to settle (no agents connected → `.error`) so it
            // can't race application shutdown during test teardown.
            var provisioned: Volume?
            for _ in 0..<100 {
                provisioned = try await Volume.query(on: app.db).first()
                if provisioned?.status == .error { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(provisioned?.status == .error)
        }
    }
}
