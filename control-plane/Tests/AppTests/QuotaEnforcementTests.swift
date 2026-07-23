import Testing
import Vapor
import Fluent
import SQLKit
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
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
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

    // MARK: - Nested-OU (ancestor) scope resolution (issue #645)

    @Test("applicableQuotas resolves ancestor-OU quotas for a deeply nested project")
    func applicableQuotasResolvesAncestorOUs() async throws {
        try await withApp { app, _, org, _, _, _ in
            let builder = TestDataBuilder(db: app.db)
            // Org → Engineering → TeamA → Project P.
            let eng = try await builder.createOU(name: "Engineering", description: "d", organization: org)
            let teamA = try await builder.createOU(
                name: "TeamA", description: "d", organization: org, parentOU: eng)
            let project = try await builder.createProject(
                name: "P", description: "d", ou: teamA)

            let orgQuota = try await builder.createResourceQuota(name: "org", organization: org)
            let engQuota = try await builder.createResourceQuota(name: "eng", ou: eng)  // intermediate
            let teamAQuota = try await builder.createResourceQuota(name: "teamA", ou: teamA)  // direct
            let projQuota = try await builder.createResourceQuota(name: "proj", project: project)
            // A sibling OU's quota must NOT be resolved.
            let teamB = try await builder.createOU(
                name: "TeamB", description: "d", organization: org, parentOU: eng)
            _ = try await builder.createResourceQuota(name: "teamB", ou: teamB)

            let resolved = try await QuotaEnforcementService.applicableQuotas(
                for: project, environment: "development", on: app.db)
            let ids = Set(resolved.compactMap { $0.id })
            #expect(
                ids == Set([orgQuota.id, engQuota.id, teamAQuota.id, projQuota.id].compactMap { $0 }))
        }
    }

    @Test("reserve reserves against an ancestor-OU quota and rejects when it is exceeded")
    func reserveEnforcesAncestorOUQuota() async throws {
        try await withApp { app, _, org, _, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let eng = try await builder.createOU(name: "Engineering", description: "d", organization: org)
            let teamA = try await builder.createOU(
                name: "TeamA", description: "d", organization: org, parentOU: eng)
            let project = try await builder.createProject(name: "P", description: "d", ou: teamA)

            // The department cap lives on the intermediate OU, two levels above P.
            let engQuota = try await builder.createResourceQuota(
                name: "dept", maxVCPUs: 4, ou: eng)

            // A create that fits is reserved against the ancestor quota.
            try await QuotaEnforcementService.reserve(
                for: project, environment: "development",
                vcpus: 3, memory: gb(2), storage: gb(10), on: app.db)
            let afterReserve = try await ResourceQuota.find(engQuota.id, on: app.db)!
            #expect(afterReserve.reservedVCPUs == 3)
            #expect(afterReserve.vmCount == 1)

            // A create for a VM row so the resync baseline reflects the first reservation.
            _ = try await builder.createVM(name: "first", project: project)  // cpu 2

            // The next create would push the department past its 4-vCPU cap → rejected.
            await #expect(throws: Abort.self) {
                try await QuotaEnforcementService.reserve(
                    for: project, environment: "development",
                    vcpus: 3, memory: gb(1), storage: gb(1), on: app.db)
            }
        }
    }

    @Test("calculateActualUsage reports non-zero usage for an intermediate-OU quota")
    func intermediateOUQuotaReportsUsage() async throws {
        try await withApp { app, _, org, _, _, _ in
            let builder = TestDataBuilder(db: app.db)
            // Org → Engineering → TeamA → Project P (grandchild of Engineering).
            let eng = try await builder.createOU(name: "Engineering", description: "d", organization: org)
            let teamA = try await builder.createOU(
                name: "TeamA", description: "d", organization: org, parentOU: eng)
            let project = try await builder.createProject(name: "P", description: "d", ou: teamA)

            _ = try await builder.createVM(name: "a", project: project)  // cpu 2
            _ = try await builder.createVM(name: "b", project: project)  // cpu 2

            let engQuota = try await builder.createResourceQuota(name: "dept", ou: eng)
            let (usage, vms, _) = try await engQuota.calculateActualUsage(on: app.db)
            // Before the fix this aggregated over the empty set and reported 0.
            #expect(vms.count == 2)
            #expect(usage.vcpus == 4)
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

    // MARK: - Sandbox accounting (issue #415)

    @Test("reserveSandbox draws from the shared vCPU/memory pools and its own count")
    func reserveSandboxSharesPools() async throws {
        try await withApp { app, _, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let quota = try await builder.createResourceQuota(
                name: "shared", maxVCPUs: 10, project: project)

            try await QuotaEnforcementService.reserveSandbox(
                for: project, environment: "development",
                vcpus: 3, memory: gb(4), on: app.db)

            let refreshed = try await ResourceQuota.find(quota.id, on: app.db)!
            #expect(refreshed.reservedVCPUs == 3)
            #expect(refreshed.reservedMemory == gb(4))
            // Sandboxes reserve no storage and must not consume a VM slot.
            #expect(refreshed.reservedStorage == 0)
            #expect(refreshed.vmCount == 0)
            #expect(refreshed.sandboxCount == 1)
        }
    }

    @Test("VMs and sandboxes exhaust the same vCPU pool")
    func vmAndSandboxShareVCPUPool() async throws {
        try await withApp { app, _, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            // An existing VM occupies 2 of the pool's 4 vCPUs; the admission
            // resync picks it up from its row.
            _ = try await builder.createVM(name: "pool-vm", project: project)  // cpu 2
            _ = try await builder.createResourceQuota(
                name: "pool", maxVCPUs: 4, project: project)

            // 2 (VM) + 3 (sandbox) exceeds the shared pool of 4.
            await #expect(throws: Abort.self) {
                try await QuotaEnforcementService.reserveSandbox(
                    for: project, environment: "development",
                    vcpus: 3, memory: gb(1), on: app.db)
            }

            // A sandbox that fits the remaining 2 vCPUs is admitted.
            try await QuotaEnforcementService.reserveSandbox(
                for: project, environment: "development",
                vcpus: 2, memory: gb(1), on: app.db)
        }
    }

    @Test("reserveSandbox is rejected by the sandbox count limit, not max_vms")
    func sandboxCountLimitEnforced() async throws {
        try await withApp { app, _, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let quota = try await builder.createResourceQuota(
                name: "counted", maxVCPUs: 100, maxVMs: 5, project: project)
            quota.maxSandboxes = 1
            try await quota.save(on: app.db)

            try await QuotaEnforcementService.reserveSandbox(
                for: project, environment: "development",
                vcpus: 1, memory: gb(1), on: app.db)
            _ = try await builder.createSandbox(name: "first", project: project)

            await #expect(throws: Abort.self) {
                try await QuotaEnforcementService.reserveSandbox(
                    for: project, environment: "development",
                    vcpus: 1, memory: gb(1), on: app.db)
            }

            // The sandbox limit must not affect VM admission.
            try await QuotaEnforcementService.reserve(
                for: project, environment: "development",
                vcpus: 1, memory: gb(1), storage: gb(1), on: app.db)
        }
    }

    @Test("resync counts pre-existing sandboxes into the baseline")
    func resyncIncludesSandboxes() async throws {
        try await withApp { app, _, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)

            // The sandbox predates the quota, so the quota never accounted for
            // it at creation — the next reserve's resync must pick it up.
            _ = try await builder.createSandbox(name: "early", project: project)  // 1 cpu, 1 GiB
            let quota = try await builder.createResourceQuota(
                name: "late", maxVCPUs: 100, project: project)

            try await QuotaEnforcementService.reserve(
                for: project, environment: "development",
                vcpus: 2, memory: gb(2), storage: gb(10), on: app.db)

            let refreshed = try await ResourceQuota.find(quota.id, on: app.db)!
            #expect(refreshed.reservedVCPUs == 3)  // sandbox 1 + VM 2
            #expect(refreshed.reservedMemory == gb(3))
            #expect(refreshed.vmCount == 1)
            #expect(refreshed.sandboxCount == 1)
        }
    }

    @Test("release(for sandbox:) recomputes without erasing other reservations")
    func sandboxReleaseRecomputes() async throws {
        try await withApp { app, _, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let quota = try await builder.createResourceQuota(
                name: "mixed", maxVCPUs: 100, project: project)

            let vm = try await builder.createVM(name: "stays", project: project)  // cpu 2
            let sandbox = try await builder.createSandbox(name: "goes", project: project)  // 1 cpu

            // Bring the counters up to date with both workloads.
            try await QuotaEnforcementService.release(for: vm, on: app.db)
            let before = try await ResourceQuota.find(quota.id, on: app.db)!
            #expect(before.reservedVCPUs == 3)
            #expect(before.vmCount == 1)
            #expect(before.sandboxCount == 1)

            try await sandbox.delete(on: app.db)
            try await QuotaEnforcementService.release(for: sandbox, on: app.db)

            let after = try await ResourceQuota.find(quota.id, on: app.db)!
            #expect(after.reservedVCPUs == 2)  // the VM's reservation survives
            #expect(after.vmCount == 1)
            #expect(after.sandboxCount == 0)
        }
    }

    @Test("the migration recount corrects counters left by the interim VM-shaped path")
    func migrationRecountCorrectsCounters() async throws {
        try await withApp { app, _, org, project, _, _ in
            let builder = TestDataBuilder(db: app.db)

            // Simulate a pre-upgrade state: a sandbox that was reserved through
            // the VM-shaped path (so it sits in vm_count) plus a real VM, on an
            // org-scoped quota so the recount exercises scope resolution.
            _ = try await builder.createVM(name: "real-vm", project: project)
            _ = try await builder.createSandbox(name: "old-sandbox", project: project)
            let quota = try await builder.createResourceQuota(name: "upgraded", organization: org)
            quota.vmCount = 2  // interim path counted the sandbox as a VM
            quota.sandboxCount = 0
            try await quota.save(on: app.db)

            guard let sql = app.db as? SQLDatabase else {
                Issue.record("test database is not SQL-backed")
                return
            }
            try await sql.raw(
                SQLQueryString(
                    AddSandboxCountToResourceQuota.recountSQL(
                        workloadTable: "sandboxes", countColumn: "sandbox_count"))
            ).run()
            try await sql.raw(
                SQLQueryString(
                    AddSandboxCountToResourceQuota.recountSQL(workloadTable: "vms", countColumn: "vm_count"))
            ).run()

            let recounted = try await ResourceQuota.find(quota.id, on: app.db)!
            #expect(recounted.vmCount == 1)
            #expect(recounted.sandboxCount == 1)
        }
    }

    @Test("POST /api/sandboxes is rejected (403) when a quota is exceeded")
    func sandboxCreateRejectedWhenQuotaExceeded() async throws {
        try await withApp { app, _, _, project, _, token in
            struct CreateSandboxBody: Content {
                let name: String
                let image: String
                let projectId: UUID?
                let cpus: Int?
                let memory: Int64?
            }

            let builder = TestDataBuilder(db: app.db)
            let quota = try await builder.createResourceQuota(
                name: "cpu-limited", maxVCPUs: 2, project: project)

            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSandboxBody(
                        name: "too-big", image: "ghcr.io/acme/worker:v1",
                        projectId: project.id, cpus: 8, memory: gb(1)))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                // Same frontend contract as VMs: the reason must contain "quota".
                #expect(res.body.string.range(of: "quota", options: .caseInsensitive) != nil)
            }

            // Nothing reserved and no row: the rejection rolled the transaction back.
            let refreshed = try await ResourceQuota.find(quota.id, on: app.db)!
            #expect(refreshed.reservedVCPUs == 0)
            #expect(refreshed.sandboxCount == 0)
            let sandboxCount = try await Sandbox.query(on: app.db).count()
            #expect(sandboxCount == 0)
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
                // Creation is asynchronous (issue #259): the endpoint commits the
                // VM row + quota reservation, then accepts with an operation record.
                #expect(res.status == .accepted)
                let operation = try res.content.decode(OperationResponse.self)
                createdVMID = operation.vmId
            }

            let afterCreate = try await ResourceQuota.find(quota.id, on: app.db)!
            #expect(afterCreate.reservedVCPUs == 2)
            #expect(afterCreate.reservedMemory == gb(4))
            #expect(afterCreate.reservedStorage == gb(20))
            #expect(afterCreate.vmCount == 1)

            // Wait for the background create dispatch (which fails — no agents run
            // in tests) to complete its operation, so the DELETE below isn't
            // rejected by the pending-operation conflict guard.
            try await waitForNoPendingOperations(vmID: createdVMID!, on: app.db)

            try await app.test(.DELETE, "/api/vms/\(createdVMID!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            // Deletion is asynchronous too: the row disappears and the quota is
            // released once the background task completes.
            try await waitForVMDeletion(createdVMID!, on: app.db)

            let afterDelete = try await ResourceQuota.find(quota.id, on: app.db)!
            #expect(afterDelete.reservedVCPUs == 0)
            #expect(afterDelete.reservedMemory == 0)
            #expect(afterDelete.reservedStorage == 0)
            #expect(afterDelete.vmCount == 0)
        }
    }

    private func waitForNoPendingOperations(vmID: UUID, on db: any Database) async throws {
        for _ in 0..<100 {
            let pending = try await ResourceOperation.query(on: db)
                .filter(\.$resourceID == vmID)
                .filter(\.$status == .pending)
                .count()
            if pending == 0 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("operations for VM \(vmID) never reached a terminal state")
    }

    private func waitForVMDeletion(_ vmID: UUID, on db: any Database) async throws {
        for _ in 0..<100 {
            if try await VM.find(vmID, on: db) == nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("VM \(vmID) was never deleted")
    }
}
