import Testing
import Vapor
import Fluent
import VaporTesting
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
        let quota = ResourceQuota(
            name: "snapshot-quota",
            projectID: UUID(),
            maxVCPUs: 10,
            maxMemory: gb(20),
            maxStorage: gb(100),
            maxVMs: 5
        )
        quota.reservedStorage = reservedStorage
        quota.isEnabled = isEnabled
        return quota
    }

    // MARK: - Quota arithmetic

    @Test(
        "canAccommodateSnapshotStorage reports overflow as 'does not fit' instead of trapping",
        arguments: [Int64.max, Int64.max - 1, Int64.max / 2 + 1]
    )
    func snapshotStorageOverflowIsRejected(bytes: Int64) async throws {
        // Any non-zero reservation is enough to push these sizes over the top.
        let quota = quota(reservedStorage: Int64.max / 2 + 1)
        let check = quota.canAccommodateSnapshotStorage(bytes)
        #expect(check.allowed == false)
        #expect(check.reason?.range(of: "storage quota", options: .caseInsensitive) != nil)
    }

    @Test("reserveSnapshotStorage throws 403 rather than trapping on an overflowing size")
    func reserveSnapshotStorageThrowsOnOverflow() async throws {
        let quota = quota(reservedStorage: gb(10))
        let error = #expect(throws: Abort.self) {
            try quota.reserveSnapshotStorage(Int64.max)
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
        try quota.reserveSnapshotStorage(Int64.max)
        #expect(quota.reservedStorage == Int64.max)
    }

    @Test("A snapshot that fits is still admitted and reserved")
    func snapshotWithinQuotaIsAdmitted() async throws {
        let quota = quota(reservedStorage: gb(10))
        let check = quota.canAccommodateSnapshotStorage(gb(5))
        #expect(check.allowed)
        try quota.reserveSnapshotStorage(gb(5))
        #expect(quota.reservedStorage == gb(15))
    }

    // MARK: - Admission through the service

    @Test("reserveSandboxSnapshot answers 403 when the size would overflow the storage counter")
    func reserveSandboxSnapshotRejectsOverflow() async throws {
        try await withApp { app, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            // A VM's disk gives the quota a non-zero measured storage baseline,
            // which is what turns an `Int64.max` snapshot size into an overflow.
            _ = try await builder.createVM(name: "storage-vm", project: project)
            _ = try await builder.createResourceQuota(name: "snapshots", project: project)

            let error = await #expect(throws: Abort.self) {
                try await QuotaEnforcementService.reserveSandboxSnapshot(
                    for: project, environment: "development", size: Int64.max, on: app.db)
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
                #expect(res.status == .badRequest)
            }
            let count = try await VM.query(on: app.db).count()
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
                #expect(res.status == .badRequest)
            }
            let count = try await VM.query(on: app.db).count()
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
                #expect(res.status == .badRequest)
            }
            let count = try await VM.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    @Test("PUT /api/vms/:id rejects an oversized 'memory' with 400")
    func vmResizeRejectsOversizedMemory() async throws {
        try await withApp { app, project, _, token in
            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "resize-target", project: project)

            try await app.test(.PUT, "/api/vms/\(vm.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                req.headers.contentType = .json
                req.body = ByteBuffer(
                    data: try JSONSerialization.data(withJSONObject: ["memory": Int64.max]))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.memory == vm.memory)
        }
    }

    // MARK: - Sandbox create

    @Test(
        "POST /api/sandboxes rejects an oversized 'memory' with 400",
        arguments: [Int64.max, WorkloadSizeLimits.maxMemoryBytes + 1]
    )
    func sandboxCreateRejectsOversizedMemory(memory: Int64) async throws {
        struct CreateSandboxBody: Content {
            let name: String
            let image: String
            let projectId: UUID?
            let cpus: Int?
            let memory: Int64?
        }

        try await withApp { app, project, _, token in
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSandboxBody(
                        name: "too-much-memory", image: "ghcr.io/acme/worker:v1",
                        projectId: project.id, cpus: 1, memory: memory))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
            let count = try await Sandbox.query(on: app.db).count()
            #expect(count == 0)
        }
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
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "sizeuser", email: "size@example.com", displayName: "Size User")
            let org = try await builder.createOrganization(name: "Size Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Size Project", description: "p", organization: org)
            _ = try await builder.createNetwork(name: "default", project: project)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, project, image, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
