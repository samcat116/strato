import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// Tests for quota enforcement wired into the VM lifecycle (VMController.create /
/// delete via QuotaEnforcementService). Covers scope resolution, environment
/// matching, reservation/release accounting, and the HTTP-level 403 that PR #300's
/// frontend relies on (it links to /quotas whenever an error reason matches /quota/i).
@Suite("Quota Enforcement Tests", .serialized)
final class QuotaEnforcementTests {

    // Body mirroring VMController's private CreateVMRequest so tests can POST /api/vms.
    struct CreateVMBody: Content {
        let name: String
        let imageId: UUID?
        let projectId: UUID?
        let environment: String?
        let cpu: Int?
        let memory: Int64?
        let disk: Int64?
    }

    private func gb(_ value: Double) -> Int64 { Int64(value * 1024 * 1024 * 1024) }

    /// Boots a configured app with a member user (currentOrganization set), org,
    /// project, and a ready image, ready to POST /api/vms.
    private func withApp(
        _ test: (Application, User, Organization, Project, Image, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            app.spicedbMockAllows = true

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "quotauser", email: "quota@example.com")
            let org = try await builder.createOrganization(name: "Quota Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Quota Project", description: "p", organization: org)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, org, project, image, token)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            await app.dropTestSchemaIfNeeded()
            try await app.asyncShutdown()
            app.cleanupTestDatabase()
            throw error
        }
        await app.dropTestSchemaIfNeeded()
        try await app.asyncShutdown()
        app.cleanupTestDatabase()
    }

    // MARK: - Service-level scope resolution

    @Test("applicableQuotas resolves project, direct OU, and root org quotas")
    func applicableQuotasResolvesHierarchy() async throws {
        try await withApp { app, _, org, _, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let ou = try await builder.createOU(name: "Eng", description: "d", organization: org)
            let project = try await builder.createProject(
                name: "OU Project", description: "d", ou: ou)

            let orgQuota = try await builder.createResourceQuota(name: "org", organization: org)
            let ouQuota = try await builder.createResourceQuota(name: "ou", ou: ou)
            let projQuota = try await builder.createResourceQuota(name: "proj", project: project)
            // An unrelated project's quota must NOT be resolved.
            let otherProject = try await builder.createProject(
                name: "Other", description: "d", organization: org)
            _ = try await builder.createResourceQuota(name: "other", project: otherProject)

            let resolved = try await QuotaEnforcementService.applicableQuotas(
                for: project, environment: "development", on: app.db)
            let ids = Set(resolved.compactMap { $0.id })
            #expect(ids == Set([orgQuota.id, ouQuota.id, projQuota.id].compactMap { $0 }))
        }
    }

    @Test("applicableQuotas honors environment scoping")
    func applicableQuotasHonorsEnvironment() async throws {
        try await withApp { app, _, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let allEnv = try await builder.createResourceQuota(name: "all", project: project)
            let prod = try await builder.createResourceQuota(
                name: "prod", project: project, environment: "production")
            _ = try await builder.createResourceQuota(
                name: "staging", project: project, environment: "staging")

            let resolved = try await QuotaEnforcementService.applicableQuotas(
                for: project, environment: "production", on: app.db)
            let ids = Set(resolved.compactMap { $0.id })
            // The unscoped quota plus the production one; never the staging one.
            #expect(ids == Set([allEnv.id, prod.id].compactMap { $0 }))
        }
    }

    // MARK: - Service-level reserve / release

    @Test("reserve increments every applicable quota")
    func reserveIncrementsQuotas() async throws {
        try await withApp { app, _, org, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let orgQuota = try await builder.createResourceQuota(
                name: "org", maxVCPUs: 10, organization: org)
            let projQuota = try await builder.createResourceQuota(
                name: "proj", maxVCPUs: 10, project: project)

            try await QuotaEnforcementService.reserve(
                for: project, environment: "development",
                vcpus: 3, memory: gb(4), storage: gb(20), on: app.db)

            let refreshedOrg = try await ResourceQuota.find(orgQuota.id, on: app.db)!
            let refreshedProj = try await ResourceQuota.find(projQuota.id, on: app.db)!
            #expect(refreshedOrg.reservedVCPUs == 3)
            #expect(refreshedOrg.vmCount == 1)
            #expect(refreshedProj.reservedVCPUs == 3)
            #expect(refreshedProj.vmCount == 1)
        }
    }

    @Test("reserve rejects when a quota cannot accommodate the VM")
    func reserveRejectsWhenExceeded() async throws {
        try await withApp { app, _, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            _ = try await builder.createResourceQuota(
                name: "tight", maxVCPUs: 2, project: project)

            await #expect(throws: Abort.self) {
                try await QuotaEnforcementService.reserve(
                    for: project, environment: "development",
                    vcpus: 4, memory: gb(1), storage: gb(1), on: app.db)
            }
        }
    }

    @Test("reserve does not partially reserve when one of several quotas rejects")
    func reserveIsAllOrNothing() async throws {
        try await withApp { app, _, org, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let roomyOrg = try await builder.createResourceQuota(
                name: "org", maxVCPUs: 100, organization: org)
            _ = try await builder.createResourceQuota(
                name: "tight", maxVCPUs: 1, project: project)

            await #expect(throws: Abort.self) {
                try await QuotaEnforcementService.reserve(
                    for: project, environment: "development",
                    vcpus: 4, memory: gb(1), storage: gb(1), on: app.db)
            }

            // The roomy org quota must be untouched: the tight project quota failed
            // the pre-flight check, so nothing was reserved anywhere.
            let refreshed = try await ResourceQuota.find(roomyOrg.id, on: app.db)!
            #expect(refreshed.reservedVCPUs == 0)
            #expect(refreshed.vmCount == 0)
        }
    }

    @Test("disabled quotas never block but still track reservations")
    func disabledQuotaTracksButDoesNotBlock() async throws {
        try await withApp { app, _, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let quota = try await builder.createResourceQuota(
                name: "disabled", maxVCPUs: 1, project: project)
            quota.isEnabled = false
            try await quota.save(on: app.db)

            // vcpus(4) exceeds max(1) but the quota is disabled → no throw.
            try await QuotaEnforcementService.reserve(
                for: project, environment: "development",
                vcpus: 4, memory: gb(1), storage: gb(1), on: app.db)

            let refreshed = try await ResourceQuota.find(quota.id, on: app.db)!
            #expect(refreshed.reservedVCPUs == 4)
            #expect(refreshed.vmCount == 1)
        }
    }

    @Test("release recomputes usage and does not erase reservations of other VMs")
    func releaseDoesNotEraseOtherReservations() async throws {
        try await withApp { app, _, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)

            // vmA predates the quota, so the quota is created with zero reservations
            // that never accounted for it (mirrors ResourceQuotaController.createQuota).
            let vmA = try await builder.createVM(name: "a", project: project)  // cpu 2
            let quota = try await builder.createResourceQuota(
                name: "late", maxVCPUs: 100, project: project)

            // vmB is created under the quota. reserve resyncs to real usage (vmA) then
            // adds vmB, so the counters reflect both once vmB's row exists.
            try await QuotaEnforcementService.reserve(
                for: project, environment: "development",
                vcpus: 2, memory: gb(2), storage: gb(10), on: app.db)
            _ = try await builder.createVM(name: "b", project: project)  // cpu 2

            let afterReserve = try await ResourceQuota.find(quota.id, on: app.db)!
            #expect(afterReserve.reservedVCPUs == 4)  // vmA + vmB
            #expect(afterReserve.vmCount == 2)

            // Deleting vmA must not drag vmB's reservation down with it: a blind
            // decrement of vmA's 2 vCPUs would erase vmB and drop the count to zero.
            try await vmA.delete(on: app.db)
            try await QuotaEnforcementService.release(for: vmA, on: app.db)

            let afterDelete = try await ResourceQuota.find(quota.id, on: app.db)!
            #expect(afterDelete.reservedVCPUs == 2)  // vmB preserved
            #expect(afterDelete.vmCount == 1)
        }
    }

    // MARK: - HTTP integration

    @Test("POST /api/vms is rejected (403) when a project quota is exceeded")
    func createRejectedWhenQuotaExceeded() async throws {
        try await withApp { app, _, _, project, image, token in
            let builder = TestDataBuilder(db: app.db)
            let quota = try await builder.createResourceQuota(
                name: "cpu-limited", maxVCPUs: 2, project: project)

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "too-big", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 8, memory: gb(2), disk: gb(10)))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                // The frontend surfaces the inline quota error only when the reason
                // matches /quota/i, so the word must be present.
                #expect(res.body.string.range(of: "quota", options: .caseInsensitive) != nil)
            }

            // Nothing reserved: the rejection rolled the transaction back.
            let refreshed = try await ResourceQuota.find(quota.id, on: app.db)!
            #expect(refreshed.reservedVCPUs == 0)
            #expect(refreshed.vmCount == 0)
            let vmCount = try await VM.query(on: app.db).count()
            #expect(vmCount == 0)
        }
    }

    @Test("POST /api/vms reserves quota on success and DELETE releases it")
    func createReservesAndDeleteReleases() async throws {
        try await withApp { app, _, _, project, image, token in
            let builder = TestDataBuilder(db: app.db)
            let quota = try await builder.createResourceQuota(
                name: "roomy", maxVCPUs: 10, maxMemoryGB: 64, maxStorageGB: 500,
                maxVMs: 10, project: project)

            var createdVMID: UUID?
            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "fits", imageId: image.id, projectId: project.id,
                        environment: "development", cpu: 2, memory: gb(4), disk: gb(20)))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let vm = try res.content.decode(VM.self)
                createdVMID = vm.id
            }

            let afterCreate = try await ResourceQuota.find(quota.id, on: app.db)!
            #expect(afterCreate.reservedVCPUs == 2)
            #expect(afterCreate.reservedMemory == gb(4))
            #expect(afterCreate.reservedStorage == gb(20))
            #expect(afterCreate.vmCount == 1)

            try await app.test(.DELETE, "/api/vms/\(createdVMID!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let afterDelete = try await ResourceQuota.find(quota.id, on: app.db)!
            #expect(afterDelete.reservedVCPUs == 0)
            #expect(afterDelete.reservedMemory == 0)
            #expect(afterDelete.reservedStorage == 0)
            #expect(afterDelete.vmCount == 0)
        }
    }
}
