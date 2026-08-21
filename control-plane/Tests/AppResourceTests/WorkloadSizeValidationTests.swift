import ControlPlanePostgres
import Testing
import Vapor
import VaporTesting
import AppTestSupport
@testable import App

/// Regression tests for issue #826: the snapshot-storage quota check added a
/// caller-influenced byte count to `reservedStorage` with the plain *trapping*
/// `+` / `+=`, unlike every sibling admission check in the same file. Because
/// VM/sandbox `memory` had no upper bound at create — only a `> 0` floor — an
/// authenticated user could seed a snapshot's size near `Int64.max` and crash
/// the control-plane replica handling the request.
///
/// These tests pin both halves of the fix: the quota math treats overflow as
/// "does not fit" (a clean `403`, never a trap), and oversized `memory` /
/// `disk` / `maxMemory` are rejected with `400` at the create boundary,
/// mirroring the existing vCPU and volume-size ceilings.
@Suite("Workload Size Validation Tests", .serialized)
final class WorkloadSizeValidationTests {

    private func gb(_ value: Double) -> Int64 { Int64(value * 1024 * 1024 * 1024) }

    private func quota(reservedStorage: Int64, isEnabled: Bool = true) -> ResourceQuota {
        ResourceQuota(
            name: "snapshot-quota",
            projectID: UUID(),
            maxVCPUs: 10,
            maxMemory: gb(20),
            maxStorage: gb(100),
            maxVMs: 5,
            isEnabled: isEnabled,
            reservedStorage: reservedStorage
        )
    }

    // MARK: - Quota arithmetic

    @Test(
        "canAccommodateSnapshotStorage reports overflow as 'does not fit' instead of trapping",
        arguments: [Int64.max, Int64.max - 1, Int64.max / 2 + 1]
    )
    func snapshotStorageOverflowIsRejected(bytes: Int64) async throws {
        // Any non-zero reservation is enough to push these sizes over the top.
        let quota = quota(reservedStorage: Int64.max / 2 + 1)
        let check = quota.canAccommodateStorage(bytes, for: "the snapshot")
        #expect(check.allowed == false)
        #expect(check.reason?.range(of: "storage quota", options: .caseInsensitive) != nil)
    }

    @Test("reserveSnapshotStorage throws 403 rather than trapping on an overflowing size")
    func reserveSnapshotStorageThrowsOnOverflow() async throws {
        let quota = quota(reservedStorage: gb(10))
        let error = #expect(throws: Abort.self) {
            _ = try quota.reservingStorage(Int64.max, for: "the snapshot")
        }
        #expect(error?.status == .forbidden)
        // The rejection must not have moved the counter.
        #expect(quota.reservedStorage == gb(10))
    }

    @Test("A disabled quota tracks an overflowing reservation by saturating, not trapping")
    func disabledQuotaSaturates() async throws {
        // A disabled quota never blocks but still tracks reservations, so the
        // unbounded operand reaches the add with no check in front of it.
        let quota = quota(reservedStorage: Int64.max - 10, isEnabled: false)
        let updated = try quota.reservingStorage(Int64.max, for: "the snapshot")
        #expect(updated.reservedStorage == Int64.max)
    }

    @Test("A disabled quota saturates the VM and sandbox counters too, rather than trapping")
    func disabledQuotaSaturatesWorkloadCounters() async throws {
        let vmQuota = quota(reservedStorage: Int64.max - 10, isEnabled: false)
            .replacingCounters(reservedVCPUs: Int.max - 1, reservedMemory: Int64.max - 10)
        let updatedVMQuota = try vmQuota.reservingResources(
            vcpus: Int.max, memory: Int64.max, storage: Int64.max)
        #expect(updatedVMQuota.reservedVCPUs == Int.max)
        #expect(updatedVMQuota.reservedMemory == Int64.max)
        #expect(updatedVMQuota.reservedStorage == Int64.max)
        #expect(updatedVMQuota.vmCount == 1)

        let sandboxQuota = quota(reservedStorage: 0, isEnabled: false)
            .replacingCounters(reservedVCPUs: Int.max - 1, reservedMemory: Int64.max - 10)
        let updatedSandboxQuota = try sandboxQuota.reservingSandboxResources(
            vcpus: Int.max, memory: Int64.max)
        #expect(updatedSandboxQuota.reservedVCPUs == Int.max)
        #expect(updatedSandboxQuota.reservedMemory == Int64.max)
        #expect(updatedSandboxQuota.sandboxCount == 1)
    }

    @Test("A negative snapshot size floors the counter at zero rather than going negative")
    func negativeSnapshotSizeFloorsAtZero() async throws {
        // The export path reserves an agent-reported size, so a negative
        // operand is not hypothetical; a negative reservation is meaningless
        // for a counter that caches measured usage.
        let quota = quota(reservedStorage: gb(1))
        let updated = try quota.reservingStorage(gb(-5), for: "the snapshot")
        #expect(updated.reservedStorage == 0)
    }

    @Test("A snapshot that fits is still admitted and reserved")
    func snapshotWithinQuotaIsAdmitted() async throws {
        let quota = quota(reservedStorage: gb(10))
        let check = quota.canAccommodateStorage(gb(5), for: "the snapshot")
        #expect(check.allowed)
        let updated = try quota.reservingStorage(gb(5), for: "the snapshot")
        #expect(updated.reservedStorage == gb(15))
    }

    @Test("A snapshot exactly filling the remaining storage is admitted")
    func snapshotAtLimitIsAdmitted() async throws {
        let quota = quota(reservedStorage: gb(40))
        let remaining = quota.maxStorage - quota.reservedStorage
        let check = quota.canAccommodateStorage(remaining, for: "the snapshot")
        #expect(check.allowed)
        let updated = try quota.reservingStorage(remaining, for: "the snapshot")
        #expect(updated.reservedStorage == quota.maxStorage)
    }

    // MARK: - Admission through the service

    @Test("reserveSnapshotStorage answers 403 when the size would overflow the storage counter")
    func reserveSnapshotStorageRejectsOverflow() async throws {
        try await withApp { app, project, _, _ in
            let builder = TestDataBuilder(db: app.testPostgres)
            // A VM's disk gives the quota a non-zero measured storage baseline,
            // which is what turns an `Int64.max` snapshot size into an overflow.
            _ = try await builder.createVM(name: "storage-vm", project: project)
            _ = try await builder.createResourceQuota(name: "snapshots", project: project)

            let error = await #expect(throws: Abort.self) {
                try await QuotaEnforcementService.reserveSnapshotStorage(
                    for: project, environment: "development", size: Int64.max, on: app.testPostgres)
            }
            #expect(error?.status == .forbidden)
        }
    }

    // MARK: - VM create

    struct CreateVMBody: Content {
        let name: String
        let imageId: UUID?
        let projectId: UUID?
        let networkName: String?
        var cpu: Int? = nil
        var memory: Int64? = nil
        var disk: Int64? = nil
        var maxMemory: Int64? = nil
    }

    struct CreateSandboxBody: Content {
        let name: String
        let image: String
        let projectId: UUID?
        let cpus: Int?
        let memory: Int64?
    }

    /// Asserts a rejection came from the new size guard rather than from any
    /// other 400 those routes can produce (a decode failure, a missing network,
    /// an image problem).
    private func expectSizeRejection(_ res: TestingHTTPResponse) {
        #expect(res.status == .badRequest)
        #expect(res.body.string.range(of: "must not exceed", options: .caseInsensitive) != nil)
    }

    @Test(
        "POST /api/vms rejects an oversized 'memory' with 400",
        arguments: [Int64.max, WorkloadSizeLimits.maxMemoryBytes + 1]
    )
    func vmCreateRejectsOversizedMemory(memory: Int64) async throws {
        try await withApp { app, project, image, token in
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "too-much-memory", imageId: image.id, projectId: project.id,
                        networkName: "default", memory: memory))
            } afterResponse: { res in
                // Before the fix this size was committed to the row, and the
                // snapshot path later trapped the process on it.
                self.expectSizeRejection(res)
            }
            let count = try await VM.all(on: app.testPostgres).count
            #expect(count == 0)
        }
    }

    @Test(
        "POST /api/vms rejects an oversized 'disk' with 400",
        arguments: [Int64.max, WorkloadSizeLimits.maxDiskBytes + 1]
    )
    func vmCreateRejectsOversizedDisk(disk: Int64) async throws {
        try await withApp { app, project, image, token in
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "too-much-disk", imageId: image.id, projectId: project.id,
                        networkName: "default", disk: disk))
            } afterResponse: { res in
                self.expectSizeRejection(res)
            }
            let count = try await VM.all(on: app.testPostgres).count
            #expect(count == 0)
        }
    }

    @Test("POST /api/vms rejects an oversized 'maxMemory' with 400")
    func vmCreateRejectsOversizedMaxMemory() async throws {
        try await withApp { app, project, image, token in
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "too-much-headroom", imageId: image.id, projectId: project.id,
                        networkName: "default", memory: self.gb(1), maxMemory: Int64.max))
            } afterResponse: { res in
                self.expectSizeRejection(res)
            }
            let count = try await VM.all(on: app.testPostgres).count
            #expect(count == 0)
        }
    }

    @Test("POST /api/vms accepts a workload sized exactly at every limit")
    func vmCreateAcceptsSizesAtTheLimit() async throws {
        try await withApp { app, project, image, token in
            var createdVMID: UUID?
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "exactly-at-the-limit", imageId: image.id, projectId: project.id,
                        networkName: "default", cpu: WorkloadSizeLimits.maxVCPUs,
                        memory: WorkloadSizeLimits.maxMemoryBytes,
                        disk: WorkloadSizeLimits.maxDiskBytes,
                        maxMemory: WorkloadSizeLimits.maxMemoryBytes))
            } afterResponse: { res in
                // The bounds are inclusive: an off-by-one in any of the three
                // comparisons, or a later tightening of a constant, fails here.
                #expect(res.status == .accepted)
                createdVMID = try res.content.decode(AcceptedMutation<VMDetailResponse>.self).resource.id
            }

            let vmID = try #require(createdVMID)
            let created = try #require(await VM.find(vmID, on: app.testPostgres))
            #expect(created.cpu == WorkloadSizeLimits.maxVCPUs)
            #expect(created.memory == WorkloadSizeLimits.maxMemoryBytes)
            #expect(created.disk == WorkloadSizeLimits.maxDiskBytes)
            #expect(created.maxMemory == WorkloadSizeLimits.maxMemoryBytes)

            // The background create dispatch fails (no agents run in tests);
            // let it reach a terminal state before teardown.
            try await waitForCreateToSettle(resourceID: vmID, on: app.testPostgres)
        }
    }

    @Test("PUT /api/vms/:id rejects an oversized 'memory' with 400")
    func vmResizeRejectsOversizedMemory() async throws {
        try await withApp { app, project, _, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let vm = try await builder.createVM(name: "resize-target", project: project)

            try await app.test(.PUT, "/api/vms/\(vm.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                req.headers.contentType = .json
                req.body = ByteBuffer(
                    data: try JSONSerialization.data(withJSONObject: ["memory": Int64.max]))
            } afterResponse: { res in
                self.expectSizeRejection(res)
            }

            let refreshed = try await VM.find(vm.id, on: app.testPostgres)
            #expect(refreshed?.memory == vm.memory)
        }
    }

    @Test("PUT /api/vms/:id accepts a resize to exactly the memory limit")
    func vmResizeAcceptsMemoryAtTheLimit() async throws {
        try await withApp { app, project, _, token in
            let builder = TestDataBuilder(db: app.testPostgres)
            let vm = try await builder.createVM(name: "resize-to-limit", project: project)

            try await app.test(.PUT, "/api/vms/\(vm.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                req.headers.contentType = .json
                req.body = ByteBuffer(
                    data: try JSONSerialization.data(
                        withJSONObject: ["memory": WorkloadSizeLimits.maxMemoryBytes]))
            } afterResponse: { res in
                // A stopped VM resizes inline, so this is a 200 with the VM.
                #expect(res.status == .ok)
            }

            let refreshed = try await VM.find(vm.id, on: app.testPostgres)
            #expect(refreshed?.memory == WorkloadSizeLimits.maxMemoryBytes)
            #expect(refreshed?.maxMemory == WorkloadSizeLimits.maxMemoryBytes)
        }
    }

    // MARK: - Sandbox create

    @Test(
        "POST /api/sandboxes rejects an oversized 'memory' with 400",
        arguments: [Int64.max, WorkloadSizeLimits.maxMemoryBytes + 1]
    )
    func sandboxCreateRejectsOversizedMemory(memory: Int64) async throws {
        try await withApp { app, project, _, token in
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSandboxBody(
                        name: "too-much-memory", image: "ghcr.io/acme/worker:v1",
                        projectId: project.id, cpus: 1, memory: memory))
            } afterResponse: { res in
                self.expectSizeRejection(res)
            }
            let count = try await Sandbox.all(on: app.testPostgres).count
            #expect(count == 0)
        }
    }

    @Test(
        "POST /api/sandboxes rejects an oversized 'cpus' with 400",
        arguments: [Int.max, WorkloadSizeLimits.maxVCPUs + 1]
    )
    func sandboxCreateRejectsOversizedCPUs(cpus: Int) async throws {
        // A sandbox has no `maxCpu` to bound `cpus` transitively the way a VM's
        // create does, so this is the only gate before the shared vCPU pool's
        // reservation add.
        try await withApp { app, project, _, token in
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSandboxBody(
                        name: "too-many-cpus", image: "ghcr.io/acme/worker:v1",
                        projectId: project.id, cpus: cpus, memory: self.gb(1)))
            } afterResponse: { res in
                self.expectSizeRejection(res)
            }
            let count = try await Sandbox.all(on: app.testPostgres).count
            #expect(count == 0)
        }
    }

    @Test("POST /api/sandboxes accepts a sandbox sized exactly at both limits")
    func sandboxCreateAcceptsSizesAtTheLimit() async throws {
        try await withApp { app, project, _, token in
            var createdSandboxID: UUID?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSandboxBody(
                        name: "exactly-at-the-limit", image: "ghcr.io/acme/worker:v1",
                        projectId: project.id, cpus: WorkloadSizeLimits.maxVCPUs,
                        memory: WorkloadSizeLimits.maxMemoryBytes))
            } afterResponse: { res in
                #expect(res.status == .accepted)
                createdSandboxID = try res.content.decode(AcceptedMutation<SandboxDetailResponse>.self).resource.id
            }

            let sandboxID = try #require(createdSandboxID)
            let created = try #require(await Sandbox.find(sandboxID, on: app.testPostgres))
            #expect(created.cpus == WorkloadSizeLimits.maxVCPUs)
            #expect(created.memory == WorkloadSizeLimits.maxMemoryBytes)

            try await waitForCreateToSettle(resourceID: sandboxID, on: app.testPostgres)
        }
    }

    /// Waits for the background create dispatch to fail (no agents run in
    /// tests), so an in-flight task can't outlive the test app. The failure
    /// lands as `degraded` on the workload itself since STR-152 — there is no
    /// operation row left to poll — so the workload is both the subject and the
    /// evidence, and either kind may be the one under test.
    private func waitForCreateToSettle(resourceID: UUID, on db: PostgresStoreContext) async throws {
        for _ in 0..<100 {
            if try await VM.find(resourceID, on: db)?.failedGeneration != nil { return }
            if try await Sandbox.find(resourceID, on: db)?.failedGeneration != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("the create dispatch for \(resourceID) never settled")
    }

    // MARK: - Fixture

    /// Boots a configured app with an org-admin user, project, default network
    /// and ready image, ready to POST workloads.
    private func withApp(
        _ test: (Application, Project, Image, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)

            let builder = TestDataBuilder(db: app.testPostgres)
            let user = try await builder.createUser(
                username: "sizeuser", email: "size@example.com", displayName: "Size User")
            let org = try await builder.createOrganization(name: "Size Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            try await user.replacingCurrentOrganization(org.id).save(on: app.testPostgres)

            let project = try await builder.createProject(
                name: "Size Project", description: "p", organization: org)
            _ = try await builder.createNetwork(name: "default", project: project)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            let token = try await user.generateAPIKey(on: app)

            try await test(app, project, image, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
