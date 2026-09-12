import Testing
import Vapor
import Fluent
import VaporTesting
import StratoShared
import AppTestSupport
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
        try await withVolumeTestApp { app, _, user, project, token in
            try await test(app, user, project, token)
        }
    }

    private func withVolumeTestApp(
        _ test: (Application, TestDataBuilder, User, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)

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

            try await test(app, builder, user, project, token)
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
            projectId: project.id!, environment: nil,
            sizeGB: sizeGB,
            format: "qcow2",
            volumeType: "data",
            sourceImageId: nil,
            iopsTotal: nil,
            bpsTotal: nil
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
            projectID: project.id!, environment: "development",
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

    @Test("POST /api/volumes accepts a valid sizeGB (202)")
    func createAcceptsValidSize() async throws {
        try await withVolumeTestApp { app, _, project, token in
            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(self.createBody(project: project, sizeGB: 10))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            // Placement runs on a detached task that touches app.db; wait for it
            // to settle (no agents connected → degraded) so it can't race
            // application shutdown during test teardown.
            var placed: Volume?
            for _ in 0..<100 {
                placed = try await Volume.query(on: app.db).first()
                if placed?.conditions.degraded != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(placed?.conditions.degraded != nil)
        }
    }

    @Test("POST /api/volumes refuses committed host-disk exhaustion before returning 202")
    func createRejectsInsufficientCommittedHostDisk() async throws {
        try await withVolumeTestApp { app, builder, _, project, token in
            let key = UUID().uuidString
            _ = try await builder.registerAgent(
                on: app,
                named: "disk-full-host",
                resources: AgentResources(
                    totalCPU: 16,
                    availableCPU: 16,
                    totalMemory: 1 << 34,
                    availableMemory: 1 << 34,
                    totalDisk: 100.gbToBytes!,
                    availableDisk: 5.gbToBytes!,
                    physicalFreeDisk: 80.gbToBytes!))

            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                req.headers.replaceOrAdd(name: "Idempotency-Key", value: key)
                try req.content.encode(self.createBody(project: project, sizeGB: 10))
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("disk-full-host"))
                #expect(res.body.string.contains("5 GiB"))
            }

            #expect(try await Volume.query(on: app.db).count() == 0)
            #expect(try await IdempotencyKey.query(on: app.db).count() == 0)
        }
    }

    @Test("An idempotent volume-create replay bypasses exhausted host capacity")
    func createReplayBypassesHostAdmission() async throws {
        try await withVolumeTestApp { app, builder, _, project, token in
            let agentId = try await builder.registerAgent(
                on: app,
                named: "idempotent-create-host",
                resources: AgentResources(
                    totalCPU: 16,
                    availableCPU: 16,
                    totalMemory: 1 << 34,
                    availableMemory: 1 << 34,
                    totalDisk: 10.gbToBytes!,
                    availableDisk: 10.gbToBytes!))
            let key = UUID().uuidString
            let body = self.createBody(project: project, sizeGB: 10)

            for _ in 0..<2 {
                try await app.test(.POST, "/api/volumes") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    req.headers.replaceOrAdd(name: "Idempotency-Key", value: key)
                    try req.content.encode(body)
                } afterResponse: { res in
                    #expect(res.status == .accepted)
                }
            }

            #expect(try await Volume.query(on: app.db).count() == 1)
            #expect(
                await app.coordination.activeReservations(agentIds: [agentId])[agentId]?.disk
                    == 10.gbToBytes!)
        }
    }

    @Test("Image-backed volume placement reserves the source size bound")
    func createFromImageSkipsHostThatOnlyFitsRequestedSize() async throws {
        try await withVolumeTestApp { app, builder, user, project, token in
            let smallAgentID = try await builder.registerAgent(
                on: app,
                named: "small-image-host",
                resources: AgentResources(
                    totalCPU: 16,
                    availableCPU: 16,
                    totalMemory: 1 << 34,
                    availableMemory: 1 << 34,
                    totalDisk: 30.gbToBytes!,
                    availableDisk: 30.gbToBytes!))
            let largeAgentID = try await builder.registerAgent(
                on: app,
                named: "large-image-host",
                resources: AgentResources(
                    totalCPU: 16,
                    availableCPU: 16,
                    totalMemory: 1 << 34,
                    availableMemory: 1 << 34,
                    totalDisk: 50.gbToBytes!,
                    availableDisk: 50.gbToBytes!))

            let image = try await builder.createImage(
                name: "large-sparse-image",
                project: project,
                size: 2.gbToBytes!,
                virtualSize: 40.gbToBytes!,
                uploadedBy: user)
            image.defaultDisk = 10.gbToBytes!
            try await image.save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: try user.requireID(),
                role: .admin,
                nodeType: .image,
                nodeID: try image.requireID(),
                createdBy: try user.requireID(),
                on: app.db)

            let body = CreateVolumeRequest(
                name: "from-large-image",
                description: "must use the image size for placement",
                projectId: try project.requireID(),
                environment: nil,
                sizeGB: 10,
                format: "qcow2",
                volumeType: "data",
                sourceImageId: try image.requireID(),
                iopsTotal: nil,
                bpsTotal: nil)
            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(body)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let replica = try #require(try await VolumeReplica.query(on: app.db).first())
            #expect(replica.agentId == largeAgentID)
            #expect(replica.agentId != smallAgentID)
            let volume = try #require(try await Volume.query(on: app.db).first())
            #expect(volume.size == 40.gbToBytes!)
            let reservations = await app.coordination.activeReservations(
                agentIds: [smallAgentID, largeAgentID])
            #expect(reservations[smallAgentID]?.disk ?? 0 == 0)
            #expect(reservations[largeAgentID]?.disk == 40.gbToBytes!)
        }
    }

    @Test("POST /api/volumes rejects a Firecracker-only source image")
    func createRejectsSourceImageWithoutDiskArtifact() async throws {
        try await withVolumeTestApp { app, _, user, project, token in
            let image = Image(
                name: "firecracker-only",
                description: "",
                projectID: try project.requireID(),
                architecture: .arm64,
                status: .ready,
                uploadedByID: try user.requireID())
            try await image.save(on: app.db)
            let imageID = try image.requireID()

            let checksum = String(repeating: "c", count: 64)
            try await ImageArtifact(
                imageID: imageID,
                kind: .kernel,
                format: nil,
                architecture: .arm64,
                filename: "vmlinux",
                size: 1,
                checksum: checksum,
                storagePath: "images/\(imageID)/kernel/vmlinux"
            ).save(on: app.db)
            try await ImageArtifact(
                imageID: imageID,
                kind: .rootfs,
                format: .raw,
                architecture: .arm64,
                filename: "rootfs.raw",
                size: 1,
                checksum: checksum,
                storagePath: "images/\(imageID)/rootfs/rootfs.raw"
            ).save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: try user.requireID(),
                role: .admin,
                nodeType: .image,
                nodeID: imageID,
                createdBy: try user.requireID(),
                on: app.db)

            let body = CreateVolumeRequest(
                name: "from-firecracker",
                description: "must be rejected",
                projectId: try project.requireID(),
                environment: nil,
                sizeGB: 10,
                format: "qcow2",
                volumeType: "data",
                sourceImageId: imageID,
                iopsTotal: nil,
                bpsTotal: nil)
            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(body)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("disk-image"))
            }

            #expect(try await Volume.query(on: app.db).count() == 0)
        }
    }

    @Test("POST /api/volumes rejects an unimplemented replicated default pool")
    func createRejectsReplicatedPool() async throws {
        try await withVolumeTestApp { app, _, project, token in
            let pool = try await StoragePool.defaultPool(on: app.db)
            pool.mode = .replicated
            pool.replicationFactor = 2
            try await pool.save(on: app.db)

            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(self.createBody(project: project, sizeGB: 10))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            #expect(try await Volume.query(on: app.db).count() == 0)
            #expect(try await VolumeReplica.query(on: app.db).count() == 0)
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

    // MARK: - Attachment is no longer a reason to refuse (STR-19)

    private func registerAgent(app: Application, named name: String) async throws -> String {
        try await TestDataBuilder(db: app.db).registerAgent(
            on: app, named: name, hostname: "\(name).test")
    }

    /// The behavioural inversion STR-19 is for: this same request used to
    /// answer `409 "Detach it first."`
    ///
    /// It is accepted rather than performed. No agent has an online grow path
    /// yet, so the volume will sit unconverged until the agent-side work lands —
    /// which is the deliberate trade for not gating the request on whichever
    /// agent happens to hold the volume.
    @Test("POST /api/volumes/:id/resize grows an attached volume")
    func resizeAcceptsAnAttachedVolume() async throws {
        try await withVolumeTestApp { app, builder, user, project, token in
            let agentId = try await self.registerAgent(app: app, named: "resize-agent")
            let vm = try await builder.createVM(name: "resize-vm", project: project)
            let volume = try await self.makeAvailableVolume(
                app: app, user: user, project: project, sizeGB: 10)
            volume.$vm.id = try vm.requireID()
            volume.deviceName = "disk1"
            volume.status = .attached
            try await volume.save(on: app.db)
            try await placeVolume(volume, on: agentId, using: app.db)
            let generationBefore = volume.generation

            try await app.test(.POST, "/api/volumes/\(volume.id!)/resize") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ResizeVolumeRequest(sizeGB: 20))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let reloaded = try #require(try await Volume.find(volume.id!, on: app.db))
            #expect(reloaded.size == 20.gbToBytes!)
            #expect(reloaded.generation == generationBefore + 1)
            // Accepted, not done: the agent has not seen the new generation.
            #expect(reloaded.conditions.converged == false)
        }
    }

    /// Shrinking stays refused whether or not the volume is attached — one
    /// grow-only rule, not a separate attached-shrink guard.
    @Test("POST /api/volumes/:id/resize still refuses to shrink an attached volume")
    func resizeRefusesAnAttachedShrink() async throws {
        try await withVolumeTestApp { app, builder, user, project, token in
            let agentId = try await self.registerAgent(app: app, named: "shrink-agent")
            let vm = try await builder.createVM(name: "shrink-vm", project: project)
            let volume = try await self.makeAvailableVolume(
                app: app, user: user, project: project, sizeGB: 10)
            volume.$vm.id = try vm.requireID()
            volume.deviceName = "disk1"
            volume.status = .attached
            try await volume.save(on: app.db)
            try await placeVolume(volume, on: agentId, using: app.db)

            try await app.test(.POST, "/api/volumes/\(volume.id!)/resize") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ResizeVolumeRequest(sizeGB: 5))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let reloaded = try await Volume.find(volume.id!, on: app.db)
            #expect(reloaded?.size == 10.gbToBytes!)
        }
    }

    /// What `canResize` refuses now that attachment does not: a volume with no
    /// size left to converge on.
    @Test("POST /api/volumes/:id/resize refuses a terminating volume")
    func resizeRefusesATerminatingVolume() async throws {
        try await withVolumeTestApp { app, user, project, token in
            let volume = try await self.makeAvailableVolume(
                app: app, user: user, project: project, sizeGB: 10)
            volume.desiredStatus = .absent
            try await volume.save(on: app.db)

            try await app.test(.POST, "/api/volumes/\(volume.id!)/resize") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ResizeVolumeRequest(sizeGB: 20))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            let reloaded = try await Volume.find(volume.id!, on: app.db)
            #expect(reloaded?.size == 10.gbToBytes!)
        }
    }
}
