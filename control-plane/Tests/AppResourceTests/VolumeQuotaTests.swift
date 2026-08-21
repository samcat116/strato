import ControlPlanePostgres
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// STR-181: volumes, volume snapshots and clones draw on `ResourceQuota`.
///
/// Before this, `maxStorage` charged VM disks, sandbox snapshots and VM
/// checkpoints and nothing else — so the one storage object a caller could
/// create directly, repeatedly, at up to 256 TiB a time was the only one nobody
/// counted. These tests pin both halves: what the aggregate *measures*, and what
/// the write paths *admit*.
@Suite("Volume Quota Tests", .serialized)
final class VolumeQuotaTests {

    private func gb(_ value: Int) -> Int64 { Int64(value) * 1024 * 1024 * 1024 }

    /// A configured app with an org-admin user, a project, and an API token —
    /// enough to drive `/api/volumes` and to seed quotas underneath it.
    private func withVolumeQuotaApp(
        _ test: (Application, TestDataBuilder, User, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)

            let builder = TestDataBuilder(db: app.testPostgres)
            let user = try await builder.createUser(
                username: "volquotauser", email: "volquota@example.com")
            let org = try await builder.createOrganization(name: "Volume Quota Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            try await user.replacingCurrentOrganization(org.id).save(on: app.testPostgres)

            let project = try await builder.createProject(
                name: "Volume Quota Project", description: "p", organization: org)
            let token = try await user.generateAPIKey(on: app)

            try await test(app, builder, user, project, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func createBody(
        project: Project, name: String, sizeGB: Int, environment: String? = nil
    ) -> CreateVolumeRequest {
        CreateVolumeRequest(
            name: name, description: "q", projectId: project.id!, environment: environment,
            sizeGB: sizeGB, format: "qcow2", volumeType: "data", sourceImageId: nil,
            iopsTotal: nil, bpsTotal: nil)
    }

    /// A registered, volume-capable agent, so the endpoints that refuse an
    /// unplaced volume (`resize`, `snapshot`, `clone`) get as far as admission.
    /// It never connects, so the mutation degrades in the background — which is
    /// exactly what these tests want, since the accounting is what is under test.
    private func registerAgent(app: Application, named name: String) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: name, hostname: "\(name).test", version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16, totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40),
            hypervisors: [
                HypervisorSupport(
                    type: .qemu, available: true, accelerated: true, capabilities: .qemu)
            ],
            protocolVersion: WireProtocol.currentVersion)
        let orgID = try await Organization.all(on: app.testPostgres).first?.id
        let uuid = try await app.agentService.registerAgent(
            message, agentName: name, organizationScope: orgID.map { .organization($0) })
        return uuid.uuidString
    }

    /// A volume the caller owns and can act on, inserted directly so the tests
    /// that exercise resize/snapshot/clone start from a stable target rather
    /// than racing the async provisioning path.
    @discardableResult
    private func seedVolume(
        app: Application, user: User, project: Project, name: String, sizeGB: Int,
        environment: String = "development", agentId: String? = nil
    ) async throws -> Volume {
        let pool = try await app.storagePoolsPersistence.defaultPool()
        let volume = Volume(
            name: name, description: "seeded", projectID: try project.requireID(),
            environment: environment, size: gb(sizeGB), status: .available,
            createdByID: try user.requireID(), poolID: pool.id)
        try await app.testPostgres.transaction { db in
            try await volume.save(on: db)
            try await placeVolume(
                volume,
                on: agentId,
                at: agentId.map { _ in "/var/lib/strato/volumes/\(name).qcow2" },
                using: db
            )
            try await RoleBindingService.grant(
                principalType: .user, principalID: try user.requireID(), role: .admin,
                nodeType: .volume, nodeID: try volume.requireID(),
                createdBy: user.id, on: db)
        }
        return volume
    }

    private func measure(_ quota: ResourceQuota, on db: PostgresStoreContext) async throws -> QuotaMeasuredUsage {
        try await QuotaUsageAggregator.measure(quota: quota, on: db)
    }

    // MARK: - What the aggregate measures

    @Test("A volume and a snapshot of it both count toward measured storage")
    func volumeAndSnapshotAreMeasured() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, _ in
            let quota = try await builder.createResourceQuota(name: "q", project: project)
            #expect(try await measure(quota, on: app.testPostgres).storageBytes == 0)

            let volume = try await seedVolume(
                app: app, user: user, project: project, name: "measured", sizeGB: 100)
            #expect(try await measure(quota, on: app.testPostgres).storageBytes == gb(100))
            #expect(try await measure(quota, on: app.testPostgres).volumeCount == 1)

            var snapshot = VolumeSnapshot(
                name: "snap", description: "", volumeID: try volume.requireID(),
                projectID: try project.requireID(), environment: "development",
                size: volume.size, createdByID: try user.requireID())
            try await snapshot.save(on: app.testPostgres)

            // The snapshot has no reported footprint yet, so it is charged its
            // parent's size: 100 GiB of volume plus 100 GiB of estimate.
            #expect(try await measure(quota, on: app.testPostgres).storageBytes == gb(200))

            try await snapshot.delete(on: app.testPostgres)
            try await volume.delete(on: app.testPostgres)
            let empty = try await measure(quota, on: app.testPostgres)
            #expect(empty.storageBytes == 0)
            #expect(empty.volumeCount == 0)
        }
    }

    @Test("A reported overlay footprint does not release the parent-size reservation")
    func snapshotFootprintDoesNotReleaseReservation() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, _ in
            let quota = try await builder.createResourceQuota(name: "q", project: project)
            let volume = try await seedVolume(
                app: app, user: user, project: project, name: "parent", sizeGB: 100)

            var snapshot = VolumeSnapshot(
                name: "snap", description: "", volumeID: try volume.requireID(),
                projectID: try project.requireID(), environment: "development",
                size: volume.size, createdByID: try user.requireID())
            try await snapshot.save(on: app.testPostgres)
            #expect(try await measure(quota, on: app.testPostgres).storageBytes == gb(200))

            // What a v39 agent reports for an overlay that has barely diverged
            // remains visible on the row, but the no-later-admission bound must
            // stay reserved.
            snapshot = snapshot.replacing(observedSizeBytes: .some(4 * 1024 * 1024))
            try await snapshot.save(on: app.testPostgres)
            #expect(try await measure(quota, on: app.testPostgres).storageBytes == gb(200))
        }
    }

    @Test("applyCapturedFacts records the live footprint, never the capture-time one")
    func applyCapturedFactsRecordsCurrentSize() async throws {
        var snapshot = VolumeSnapshot(
            name: "snap", description: "", volumeID: UUID(), projectID: UUID(),
            environment: "development", size: 1 << 30, createdByID: UUID())

        // A pre-v39 agent: `sizeBytes` only, and it is the empty overlay's
        // header. Recording it would make the snapshot free.
        var update = snapshot.recordingCapturedFacts(
            ObservedSnapshotFacts(sizeBytes: 197_120, storagePath: "/v/s.qcow2"))
        #expect(update.changed)
        snapshot = update.resource
        #expect(snapshot.storagePath == "/v/s.qcow2")
        #expect(snapshot.observedSizeBytes == nil)
        #expect(snapshot.size == 1 << 30)

        // A v39 agent's live measurement lands.
        update = snapshot.recordingCapturedFacts(
            ObservedSnapshotFacts(
                sizeBytes: 197_120, currentSizeBytes: 512 << 20, storagePath: "/v/s.qcow2"))
        #expect(update.changed)
        snapshot = update.resource
        #expect(snapshot.observedSizeBytes == 512 << 20)
        #expect(snapshot.size == 1 << 30, "the restore-sizing figure must not move")

        // Sub-megabyte drift is not worth a row write: a report goes out every
        // 20 seconds and coalesces at 500 ms.
        update = snapshot.recordingCapturedFacts(
            ObservedSnapshotFacts(
                currentSizeBytes: (512 << 20) + 4096, storagePath: "/v/s.qcow2"))
        #expect(!update.changed)
        snapshot = update.resource
        #expect(snapshot.observedSizeBytes == 512 << 20)

        update = snapshot.recordingCapturedFacts(
            ObservedSnapshotFacts(
                currentSizeBytes: (512 << 20) + (2 << 20), storagePath: "/v/s.qcow2"))
        #expect(update.changed)
        snapshot = update.resource
        #expect(snapshot.observedSizeBytes == (512 << 20) + (2 << 20))
    }

    @Test("A VM's boot disk is charged exactly once as a managed volume")
    func bootVolumeIsCountedAsManagedStorage() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, _ in
            let quota = try await builder.createResourceQuota(name: "q", project: project)
            let vm = try await builder.createVM(name: "managed", project: project)

            var bootVolume = try await seedVolume(
                app: app, user: user, project: project, name: "managed-boot", sizeGB: 10)
            bootVolume = bootVolume.replacing(
                volumeType: .boot,
                vmID: try vm.requireID(),
                deviceName: "disk0",
                bootOrder: 0
            )
            try await bootVolume.save(on: app.testPostgres)

            let attached = try await measure(quota, on: app.testPostgres)
            #expect(attached.storageBytes == gb(10))
            #expect(attached.volumeCount == 1)

            // Attachment is lifecycle state, not accounting identity.
            bootVolume = bootVolume.replacing(vmID: .some(nil))
            try await bootVolume.save(on: app.testPostgres)
            let detached = try await measure(quota, on: app.testPostgres)
            #expect(detached.storageBytes == gb(10))
            #expect(detached.volumeCount == 1)

            bootVolume = bootVolume.replacing(size: gb(15))
            try await bootVolume.save(on: app.testPostgres)
            let grown = try await measure(quota, on: app.testPostgres)
            #expect(grown.storageBytes == gb(15))
            #expect(grown.volumeCount == 1)
        }
    }

    @Test("An environment-scoped quota measures only its own environment's volumes")
    func environmentScopedQuotaMeasuresItsOwnVolumes() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, _ in
            let devQuota = try await builder.createResourceQuota(
                name: "dev", project: project, environment: "development")
            let prodQuota = try await builder.createResourceQuota(
                name: "prod", project: project, environment: "production")

            try await seedVolume(
                app: app, user: user, project: project, name: "dev-vol", sizeGB: 10)
            try await seedVolume(
                app: app, user: user, project: project, name: "prod-vol", sizeGB: 40,
                environment: "production")

            #expect(try await measure(devQuota, on: app.testPostgres).storageBytes == gb(10))
            #expect(try await measure(prodQuota, on: app.testPostgres).storageBytes == gb(40))
        }
    }

    // MARK: - Admission

    @Test("POST /api/volumes is refused with 403 when it would exceed maxStorage")
    func createRefusedOverStorageQuota() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, token in
            let quota = try await builder.createResourceQuota(
                name: "small", maxStorageGB: 20, project: project)

            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(createBody(project: project, name: "too-big", sizeGB: 50))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.range(of: "quota", options: .caseInsensitive) != nil)
            }

            // Nothing was written and nothing was reserved.
            #expect(try await Volume.all(on: app.testPostgres).count == 0)
            let refreshed = try #require(try await ResourceQuota.find(quota.id, on: app.testPostgres))
            #expect(refreshed.reservedStorage == 0)
            #expect(refreshed.volumeCount == 0)
        }
    }

    @Test("A create that fits is admitted and reserved")
    func createWithinQuotaIsAdmitted() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, token in
            let quota = try await builder.createResourceQuota(
                name: "roomy", maxStorageGB: 100, project: project)

            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(createBody(project: project, name: "fits", sizeGB: 30))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let volume = try #require(try await Volume.all(on: app.testPostgres).first)
            #expect(volume.environment == "development")
            // Placement runs in the background and has no agent to land on, so
            // the row's own convergence may degrade — the accounting does not.
            let synchronized = try await QuotaEnforcementService.resyncReservations(quota, on: app.testPostgres)
            #expect(synchronized.reservedStorage == gb(30))
            #expect(synchronized.volumeCount == 1)
        }
    }

    @Test("A create names the environment it is charged to")
    func createHonoursRequestedEnvironment() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, token in
            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    createBody(
                        project: project, name: "prod-vol", sizeGB: 1, environment: "production"))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
            let volume = try #require(try await Volume.all(on: app.testPostgres).first)
            #expect(volume.environment == "production")

            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    createBody(
                        project: project, name: "nowhere", sizeGB: 1, environment: "staging-typo"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Resize is admitted against the delta, not the whole new size")
    func resizeChargesOnlyTheDelta() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, token in
            let quota = try await builder.createResourceQuota(
                name: "delta", maxStorageGB: 25, project: project)
            let agentId = try await registerAgent(app: app, named: "resize-host")
            let volume = try await seedVolume(
                app: app, user: user, project: project, name: "growable", sizeGB: 10,
                agentId: agentId)
            let volumeID = try volume.requireID()

            // 10 → 20 needs 10 more, which fits in 25 even though 20 + the
            // existing 10 would not if the whole size were charged again.
            try await app.test(.POST, "/api/volumes/\(volumeID)/resize") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ResizeVolumeRequest(sizeGB: 20))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
            let synchronized = try await QuotaEnforcementService.resyncReservations(quota, on: app.testPostgres)
            #expect(synchronized.reservedStorage == gb(20))

            // 20 → 30 needs 10 more than the 25 ceiling allows.
            try await app.test(.POST, "/api/volumes/\(volumeID)/resize") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(ResizeVolumeRequest(sizeGB: 30))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.range(of: "quota", options: .caseInsensitive) != nil)
            }
            let unchanged = try #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(unchanged.size == gb(20), "a refused resize must not move the desired size")
        }
    }

    @Test("Attaching an image-backed volume reserves its materialized virtual size")
    func imageBackedAttachReservesMaterializedSize() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, token in
            // The VM's 10 GiB boot disk and the requested 10 GiB volume leave
            // exactly enough room for the materialized volume to grow to 30.
            let quota = try await builder.createResourceQuota(
                name: "materialized", maxStorageGB: 40, project: project)
            let agentId = try await registerAgent(app: app, named: "image-volume-host")
            var vm = try await builder.createVM(name: "image-volume-vm", project: project)
            vm.hypervisorId = agentId
            try await vm.save(on: app.testPostgres)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            let volume = try await seedVolume(
                app: app, user: user, project: project, name: "image-volume", sizeGB: 10,
                agentId: agentId
            ).replacing(
                observedSizeBytes: gb(30),
                sourceImageID: try image.requireID()
            )
            try await volume.save(on: app.testPostgres)

            try await app.test(.POST, "/api/volumes/\(try volume.requireID())/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AttachVolumeRequest(
                        vmId: try vm.requireID(), deviceName: nil, bootOrder: nil, readonly: nil))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let reloaded = try #require(try await Volume.find(volume.id, on: app.testPostgres))
            #expect(reloaded.size == gb(30), "the desired size must adopt the materialized image")
            let refreshedQuota = try #require(try await ResourceQuota.find(quota.id, on: app.testPostgres))
            #expect(refreshedQuota.reservedStorage == gb(40))
        }
    }

    @Test("An image-backed volume cannot attach before or beyond materialized-size admission")
    func imageBackedAttachRequiresMaterializedSizeAdmission() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, token in
            _ = try await builder.createResourceQuota(
                name: "too-small", maxStorageGB: 30, project: project)
            let agentId = try await registerAgent(app: app, named: "guarded-image-volume-host")
            var vm = try await builder.createVM(name: "guarded-image-volume-vm", project: project)
            vm.hypervisorId = agentId
            try await vm.save(on: app.testPostgres)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            var volume = try await seedVolume(
                app: app, user: user, project: project, name: "guarded-image-volume", sizeGB: 10,
                agentId: agentId
            ).replacing(sourceImageID: try image.requireID())
            try await volume.save(on: app.testPostgres)

            func attach(expecting expected: HTTPStatus) async throws {
                try await app.test(.POST, "/api/volumes/\(try volume.requireID())/attach") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        AttachVolumeRequest(
                            vmId: try vm.requireID(), deviceName: nil, bootOrder: nil,
                            readonly: nil))
                } afterResponse: { res in
                    #expect(res.status == expected)
                }
            }

            // Before the agent reports the source's virtual size, there is no
            // trustworthy figure against which attachment can be admitted.
            try await attach(expecting: .conflict)

            // Once reported, the 30 GiB materialization plus the VM's 10 GiB
            // boot disk exceeds the 30 GiB quota and is refused atomically.
            volume = volume.replacing(observedSizeBytes: gb(30))
            try await volume.save(on: app.testPostgres)
            try await attach(expecting: .forbidden)

            let unchanged = try #require(try await Volume.find(volume.id, on: app.testPostgres))
            #expect(unchanged.size == gb(10))
            #expect(unchanged.vmID == nil)
        }
    }

    @Test("A live footprint report cannot release room for another snapshot")
    func snapshotReservationSurvivesFootprintReport() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, token in
            _ = try await builder.createResourceQuota(
                name: "tight", maxStorageGB: 110, project: project)
            let agentId = try await registerAgent(app: app, named: "snapshot-host")
            let volume = try await seedVolume(
                app: app, user: user, project: project, name: "big", sizeGB: 50, agentId: agentId)
            let volumeID = try volume.requireID()

            // The first overlay has barely diverged, but can still grow to the
            // parent volume's whole size with no later admission point.
            let first = VolumeSnapshot(
                name: "first", description: "", volumeID: volumeID,
                projectID: try project.requireID(), environment: "development",
                size: volume.size, observedSizeBytes: 4 * 1024 * 1024,
                createdByID: try user.requireID())
            try await first.save(on: app.testPostgres)

            // 50 GiB volume + 50 GiB first-snapshot bound leaves only 10 GiB,
            // so another 50 GiB bound must fail. Replacing the first bound with
            // its 4 MiB report would incorrectly admit this request.
            try await app.test(.POST, "/api/volumes/\(volumeID)/snapshot") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSnapshotRequest(name: "second", description: nil, ttlSeconds: nil))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.range(of: "quota", options: .caseInsensitive) != nil)
            }
            #expect(try await VolumeSnapshot.all(on: app.testPostgres).count == 1)
        }
    }

    @Test("A clone is admitted like a create, for the source's whole size")
    func cloneIsAdmittedLikeACreate() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, token in
            _ = try await builder.createResourceQuota(
                name: "one-copy", maxStorageGB: 60, project: project)
            let agentId = try await registerAgent(app: app, named: "clone-host")
            let volume = try await seedVolume(
                app: app, user: user, project: project, name: "source", sizeGB: 50,
                agentId: agentId)
            let volumeID = try volume.requireID()

            try await app.test(.POST, "/api/volumes/\(volumeID)/clone") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CloneVolumeRequest(name: "copy", description: nil))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.range(of: "quota", options: .caseInsensitive) != nil)
            }
            #expect(try await Volume.all(on: app.testPostgres).count == 1)
        }
    }

    @Test("maxVolumes is unset by default and enforced once set")
    func volumeCountLimitIsOptional() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, token in
            let quota = try await builder.createResourceQuota(
                name: "counted", maxStorageGB: 1000, project: project)
            #expect(quota.maxVolumes == nil)

            for index in 0..<3 {
                try await app.test(.POST, "/api/volumes") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(
                        createBody(project: project, name: "unlimited-\(index)", sizeGB: 1))
                } afterResponse: { res in
                    #expect(res.status == .accepted, "no count limit is set")
                }
            }

            let limitedQuota = quota.withMaxVolumes(3)
            try await limitedQuota.save(on: app.testPostgres)

            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(createBody(project: project, name: "one-too-many", sizeGB: 1))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.range(of: "quota", options: .caseInsensitive) != nil)
            }

            // Room reappears when one goes away.
            let victim = try #require(
                try await Volume.all(on: app.testPostgres).first { $0.name == "unlimited-0" })
            try await victim.delete(on: app.testPostgres)

            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(createBody(project: project, name: "replacement", sizeGB: 1))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
        }
    }

    // MARK: - Release

    @Test("Reaping a volume frees exactly its own bytes")
    func reapReleasesOnlyTheReapedVolume() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, _ in
            let quota = try await builder.createResourceQuota(
                name: "release", maxStorageGB: 100, project: project)
            let keeper = try await seedVolume(
                app: app, user: user, project: project, name: "keeper", sizeGB: 30)
            let doomed = try await seedVolume(
                app: app, user: user, project: project, name: "doomed", sizeGB: 20)
            let synchronized = try await QuotaEnforcementService.resyncReservations(quota, on: app.testPostgres)
            try await synchronized.save(on: app.testPostgres)
            #expect(synchronized.reservedStorage == gb(50))

            let terminating = doomed.replacingDesiredStatus(.absent)
            try await terminating.save(on: app.testPostgres)
            #expect(try await Volume.reap(terminating, on: app.testPostgres, app: app))

            let refreshed = try #require(try await ResourceQuota.find(quota.id, on: app.testPostgres))
            #expect(refreshed.reservedStorage == gb(30), "recount, not decrement")
            #expect(refreshed.volumeCount == 1)
            #expect(try await Volume.find(keeper.id, on: app.testPostgres) != nil)
        }
    }

    @Test("A volume's snapshots stop being charged with it")
    func reapReleasesTheVolumesSnapshots() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, _ in
            let quota = try await builder.createResourceQuota(
                name: "cascade", maxStorageGB: 500, project: project)
            let volume = try await seedVolume(
                app: app, user: user, project: project, name: "parent", sizeGB: 100)
            let snapshot = VolumeSnapshot(
                name: "snap", description: "", volumeID: try volume.requireID(),
                projectID: try project.requireID(), environment: "development",
                size: volume.size, createdByID: try user.requireID())
            try await snapshot.save(on: app.testPostgres)
            let synchronized = try await QuotaEnforcementService.resyncReservations(quota, on: app.testPostgres)
            try await synchronized.save(on: app.testPostgres)
            #expect(synchronized.reservedStorage == gb(200))

            let terminating = volume.replacingDesiredStatus(.absent)
            try await terminating.save(on: app.testPostgres)
            #expect(try await Volume.reap(terminating, on: app.testPostgres, app: app))

            let refreshed = try #require(try await ResourceQuota.find(quota.id, on: app.testPostgres))
            #expect(refreshed.reservedStorage == 0)
        }
    }

    // MARK: - Concurrency

    @Test("Two simultaneous creates against room for one: exactly one is admitted")
    func concurrentCreatesSerializeOnTheAdvisoryLock() async throws {
        try await withVolumeQuotaApp { app, builder, user, project, token in
            // Room for exactly one 30 GiB volume.
            _ = try await builder.createResourceQuota(
                name: "one-slot", maxStorageGB: 50, project: project)

            let bodies = (0..<2).map { createBody(project: project, name: "racer-\($0)", sizeGB: 30) }
            let statuses = await withTaskGroup(of: HTTPStatus?.self) { group in
                for body in bodies {
                    group.addTask {
                        var status: HTTPStatus?
                        try? await app.test(.POST, "/api/volumes") { req in
                            req.headers.bearerAuthorization = BearerAuthorization(token: token)
                            try req.content.encode(body)
                        } afterResponse: { res in
                            status = res.status
                        }
                        return status
                    }
                }
                return await group.reduce(into: [HTTPStatus]()) { acc, status in
                    if let status { acc.append(status) }
                }
            }

            #expect(statuses.filter { $0 == .accepted }.count == 1)
            #expect(statuses.filter { $0 == .forbidden }.count == 1)
            #expect(try await Volume.all(on: app.testPostgres).count == 1)
        }
    }
}
