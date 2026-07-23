import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// Regression tests for issue #676: an authenticated user with the ordinary
/// project-scoped `create_volume` (or `resize`) permission could hard-crash the
/// control-plane replica by sending a large `sizeGB`. The GiB→bytes conversion
/// used the *trapping* `Int64(_:Double)` initializer with no prior bounds check,
/// so an out-of-range value raised a runtime fatal error and killed the process.
///
/// These tests pin the fix: oversized, zero, and negative `sizeGB` values return
/// `400 Bad Request` on both the create and resize paths instead of crashing.
@Suite("Volume Size Validation Tests", .serialized)
final class VolumeSizeValidationTests {

    /// Boots a configured test app with a non-admin user, org, and project.
    private func withVolumeTestApp(
        _ test: (Application, User, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "volsizeuser",
                email: "volsize@example.com",
                displayName: "Volume Size User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Volume Size Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Volume Size Project",
                description: "Project for volume size validation tests",
                organization: org
            )
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, project, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    private func createBody(project: Project, sizeGB: Int) -> CreateVolumeRequest {
        CreateVolumeRequest(
            name: "size-test-vol",
            description: "volume for size validation",
            projectId: project.id!,
            sizeGB: sizeGB,
            format: "qcow2",
            volumeType: "data",
            sourceImageId: nil
        )
    }

    /// Inserts an `.available` volume owned by `user` (with the creator's admin
    /// binding, so `resize` authorizes) directly, bypassing the async
    /// provisioning path so the resize test has a stable, resizable target.
    private func makeAvailableVolume(
        app: Application, user: User, project: Project, sizeGB: Int
    ) async throws -> Volume {
        let pool = try await StoragePool.defaultPool(on: app.db)
        let volume = Volume(
            name: "resize-target",
            description: "resizable volume",
            projectID: project.id!,
            size: sizeGB.gbToBytes!,
            format: .qcow2,
            volumeType: .data,
            status: .available,
            createdByID: user.id!,
            poolID: pool.id
        )
        try await app.db.transaction { db in
            try await volume.save(on: db)
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: user.id!,
                role: .admin,
                nodeType: .volume,
                nodeID: volume.id!,
                createdBy: user.id,
                on: db
            )
        }
        return volume
    }

    // MARK: - Create

    @Test(
        "POST /api/volumes rejects invalid sizeGB with 400",
        arguments: [0, -5, Volume.maxSizeGB + 1, 9_000_000_000, Int.max]
    )
    func createRejectsInvalidSize(sizeGB: Int) async throws {
        try await withVolumeTestApp { app, _, project, token in
            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(self.createBody(project: project, sizeGB: sizeGB))
            } afterResponse: { res in
                // Before the fix, an oversized value trapped the process here.
                #expect(res.status == .badRequest)
            }

            // A rejected request must not have left a volume behind.
            let count = try await Volume.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    @Test("POST /api/volumes accepts a valid sizeGB")
    func createAcceptsValidSize() async throws {
        try await withVolumeTestApp { app, _, project, token in
            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(self.createBody(project: project, sizeGB: 10))
            } afterResponse: { res in
                #expect(res.status == .ok)
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

    // MARK: - Resize

    @Test(
        "POST /api/volumes/:id/resize rejects invalid sizeGB with 400",
        arguments: [0, -5, Volume.maxSizeGB + 1, 9_000_000_000, Int.max]
    )
    func resizeRejectsInvalidSize(sizeGB: Int) async throws {
        try await withVolumeTestApp { app, user, project, token in
            let volume = try await self.makeAvailableVolume(
                app: app, user: user, project: project, sizeGB: 10)

            try await app.test(.POST, "/api/volumes/\(volume.id!)/resize") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ResizeVolumeRequest(sizeGB: sizeGB))
            } afterResponse: { res in
                // Before the fix, an oversized value trapped the process here.
                #expect(res.status == .badRequest)
            }

            // The volume's stored size must be untouched by a rejected resize.
            let reloaded = try await Volume.find(volume.id!, on: app.db)
            #expect(reloaded?.size == 10.gbToBytes!)
            #expect(reloaded?.status == .available)
        }
    }
}
