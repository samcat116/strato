import Testing
import Vapor
import Fluent
import VaporTesting
import AppTestSupport
@testable import App

@Suite("Resource Quota API Tests", .serialized)
final class ResourceQuotaTests {

    // Helper to run tests with fresh app and test data
    func withQuotaTestApp(_ test: (Application, User, Organization, Project, String) async throws -> Void) async throws
    {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            // Create test user and organization
            let testUser = User(
                username: "testuser",
                email: "test@example.com",
                displayName: "Test User",
                isSystemAdmin: false
            )
            try await testUser.save(on: app.db)

            let testOrganization = Organization(
                name: "Test Organization",
                description: "Test organization for unit tests"
            )
            try await testOrganization.save(on: app.db)

            // Create test project
            var testProject = Project(
                name: "Test Project",
                description: "Test project",
                organizationID: testOrganization.id,
                path: ""
            )
            try await testProject.save(on: app.db)
            testProject = testProject.replacingPath(try await testProject.buildPath(on: app.db))
            try await testProject.save(on: app.db)

            // Add user to organization as admin
            _ = try await OrganizationMembershipStore.insert(
                userID: testUser.id!,
                organizationID: testOrganization.id!,
                roleID: IAMRole.admin.seededID,
                on: app.db
            )

            // The admin role binding the API/backfill would have written
            // alongside the membership row — the Cedar evaluator (#482)
            // answers from `role_bindings`.
            try await RoleBindingService.grant(
                principalType: .user, principalID: testUser.id!, role: .admin,
                nodeType: .organization, nodeID: testOrganization.id!, createdBy: nil, on: app.db)

            let authToken = try await testUser.generateAPIKey(on: app)

            try await test(app, testUser, testOrganization, testProject, authToken)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    // MARK: - Create Quota Tests

    @Test("Create organization-level quota")
    func testCreateOrganizationQuota() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/quotas") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateResourceQuotaRequest(
                        name: "Org Quota",
                        maxVCPUs: 100,
                        maxMemoryGB: 200,
                        maxStorageGB: 1000,
                        maxVMs: 50,
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: nil,
                        maxLoadBalancers: nil,
                        environment: nil,
                        isEnabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ResourceQuotaResponse.self)
                #expect(response.name == "Org Quota")
                #expect(response.limits.maxVCPUs == 100)
                #expect(response.limits.maxMemoryGB == 200)
                #expect(response.limits.maxStorageGB == 1000)
                #expect(response.limits.maxVMs == 50)
                #expect(response.entityId == testOrganization.id!)
                #expect(response.entityType == "organization")
            }
        }
    }

    @Test("Create project-level quota")
    func testCreateProjectQuota() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            try await app.test(.POST, "/api/projects/\(testProject.id!)/quotas") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateResourceQuotaRequest(
                        name: "Project Quota",
                        maxVCPUs: 20,
                        maxMemoryGB: 40,
                        maxStorageGB: 200,
                        maxVMs: 10,
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: nil,
                        maxLoadBalancers: nil,
                        environment: nil,
                        isEnabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ResourceQuotaResponse.self)
                #expect(response.name == "Project Quota")
                #expect(response.entityId == testProject.id!)
                #expect(response.entityType == "project")
            }
        }
    }

    @Test("Create environment-specific quota")
    func testCreateEnvironmentQuota() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            try await app.test(.POST, "/api/projects/\(testProject.id!)/quotas") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateResourceQuotaRequest(
                        name: "Production Quota",
                        maxVCPUs: 50,
                        maxMemoryGB: 100,
                        maxStorageGB: 500,
                        maxVMs: 25,
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: nil,
                        maxLoadBalancers: nil,
                        environment: "production",
                        isEnabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ResourceQuotaResponse.self)
                #expect(response.environment == "production")
                #expect(response.entityType == "project")  // Environment quota is still under project
            }
        }
    }

    @Test("Environment-scoped quotas reject a project-wide network limit")
    func testEnvironmentQuotaRejectsNetworkLimit() async throws {
        try await withQuotaTestApp { app, _, _, testProject, authToken in
            try await app.test(.POST, "/api/projects/\(testProject.id!)/quotas") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateResourceQuotaRequest(
                        name: "Invalid Environment Network Quota",
                        maxVCPUs: 20,
                        maxMemoryGB: 40,
                        maxStorageGB: 200,
                        maxVMs: 10,
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: 2,
                        maxLoadBalancers: nil,
                        environment: "production",
                        isEnabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("networks are project-wide"))
            }

            let quota = ResourceQuota(
                name: "Existing Environment Quota",
                projectID: testProject.id,
                maxVCPUs: 20,
                maxMemory: 40 * 1024 * 1024 * 1024,
                maxStorage: 200 * 1024 * 1024 * 1024,
                maxVMs: 10,
                environment: "production")
            try await quota.save(on: app.db)

            try await app.test(.PUT, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateResourceQuotaRequest(
                        name: nil,
                        maxVCPUs: nil,
                        maxMemoryGB: nil,
                        maxStorageGB: nil,
                        maxVMs: nil,
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: 2,
                        maxLoadBalancers: nil,
                        isEnabled: nil))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("networks are project-wide"))
            }
        }
    }

    // MARK: - Usage Tracking Tests

    @Test("Track quota usage")
    func testQuotaUsageTracking() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            // Create quota
            let quota = ResourceQuota(
                name: "Usage Test Quota",
                organizationID: testOrganization.id,
                organizationalUnitID: nil,
                projectID: nil,
                maxVCPUs: 10,
                maxMemory: Int64(20.0 * 1024 * 1024 * 1024),
                maxStorage: Int64(100.0 * 1024 * 1024 * 1024),
                maxVMs: 5
            )
            try await quota.save(on: app.db)

            // Update usage
            let usedQuota = quota.replacingCounters(
                reservedVCPUs: 4,
                reservedMemory: Int64(8.0 * 1024 * 1024 * 1024),
                reservedStorage: Int64(40.0 * 1024 * 1024 * 1024),
                vmCount: 2)
            try await usedQuota.save(on: app.db)

            // Get quota with usage
            try await app.test(.GET, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ResourceQuotaResponse.self)
                #expect(response.usage.reservedVCPUs == 4)
                #expect(response.usage.reservedMemoryGB == 8.0)
                #expect(response.usage.reservedStorageGB == 40.0)
                #expect(response.usage.vmCount == 2)

                // Check utilization percentages
                #expect(response.utilization.cpuPercent == 40.0)  // 4/10 * 100
                #expect(response.utilization.memoryPercent == 40.0)  // 8/20 * 100
                #expect(response.utilization.storagePercent == 40.0)  // 40/100 * 100
                #expect(response.utilization.vmPercent == 40.0)  // 2/5 * 100
            }
        }
    }

    @Test("Quota validation - exceeding limits")
    func testQuotaExceedsLimits() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            let quota = ResourceQuota(
                name: "Limited Quota",
                organizationID: nil,
                organizationalUnitID: nil,
                projectID: testProject.id,
                maxVCPUs: 2,
                maxMemory: Int64(4.0 * 1024 * 1024 * 1024),
                maxStorage: Int64(10.0 * 1024 * 1024 * 1024),
                maxVMs: 1
            )
            try await quota.save(on: app.db)

            // Try to use more than available
            let canUse = quota.canAccommodateVM(
                vcpus: 4,  // Exceeds limit of 2
                memory: Int64(2.0 * 1024 * 1024 * 1024),
                storage: Int64(5.0 * 1024 * 1024 * 1024)
            )

            #expect(!canUse.allowed)
        }
    }

    @Test("Sandboxes share the vCPU/memory pools but have their own count limit")
    func testSandboxAccommodation() async throws {
        try await withQuotaTestApp { app, _, _, testProject, _ in
            var quota = ResourceQuota(
                name: "Sandbox Quota",
                organizationID: nil,
                organizationalUnitID: nil,
                projectID: testProject.id,
                maxVCPUs: 4,
                maxMemory: Int64(8.0 * 1024 * 1024 * 1024),
                maxStorage: Int64(10.0 * 1024 * 1024 * 1024),
                maxVMs: 10,
                maxSandboxes: 1
            )
            try await quota.save(on: app.db)

            // A VM reservation consumes the shared vCPU pool...
            quota = try quota.reservingResources(
                vcpus: 3, memory: Int64(1024 * 1024 * 1024), storage: Int64(1024 * 1024 * 1024))

            // ...so a 2-vCPU sandbox no longer fits (3 + 2 > 4).
            let tooBig = quota.canAccommodateSandbox(vcpus: 2, memory: Int64(1024 * 1024 * 1024))
            #expect(!tooBig.allowed)

            // A 1-vCPU sandbox fits and takes the only sandbox slot.
            quota = try quota.reservingSandboxResources(vcpus: 1, memory: Int64(1024 * 1024 * 1024))
            #expect(quota.sandboxCount == 1)
            #expect(quota.vmCount == 1)

            // The count limit rejects a second sandbox even with pool room left.
            let overCount = quota.canAccommodateSandbox(vcpus: 0, memory: 0)
            #expect(!overCount.allowed)
            #expect(overCount.reason?.contains("Sandbox limit") == true)

            // Unspecified maxSandboxes follows maxVMs at construction.
            let defaulted = ResourceQuota(
                name: "Defaulted",
                projectID: testProject.id,
                maxVCPUs: 4,
                maxMemory: 1,
                maxStorage: 1,
                maxVMs: 7
            )
            #expect(defaulted.maxSandboxes == 7)
        }
    }

    // MARK: - Hierarchy Tests

    @Test("List quotas by level")
    func testListQuotasByLevel() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            // Create quotas at different levels
            let orgQuota = ResourceQuota(
                name: "Org Level",
                organizationID: testOrganization.id,
                organizationalUnitID: nil,
                projectID: nil,
                maxVCPUs: 100,
                maxMemory: Int64(200.0 * 1024 * 1024 * 1024),
                maxStorage: Int64(1000.0 * 1024 * 1024 * 1024),
                maxVMs: 50
            )
            try await orgQuota.save(on: app.db)

            let projectQuota = ResourceQuota(
                name: "Project Level",
                organizationID: nil,
                organizationalUnitID: nil,
                projectID: testProject.id,
                maxVCPUs: 20,
                maxMemory: Int64(40.0 * 1024 * 1024 * 1024),
                maxStorage: Int64(200.0 * 1024 * 1024 * 1024),
                maxVMs: 10
            )
            try await projectQuota.save(on: app.db)

            // List organization quotas
            try await app.test(.GET, "/api/quotas?level=organization") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let quotas = try res.content.decode(PagedResponse<ResourceQuotaResponse>.self).items
                #expect(quotas.allSatisfy { $0.entityType == "organization" })
            }

            // List project quotas
            try await app.test(.GET, "/api/quotas?level=project") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let quotas = try res.content.decode(PagedResponse<ResourceQuotaResponse>.self).items
                #expect(quotas.allSatisfy { $0.entityType == "project" })
            }
        }
    }

    @Test("Project quota list omits projects the caller may not read")
    func testProjectQuotaListFiltersPerRow() async throws {
        try await withQuotaTestApp { app, _, testOrganization, testProject, _ in
            // A quota on a project the member has no binding on.
            let projectQuota = ResourceQuota(
                name: "Hidden Project Quota",
                organizationID: nil, organizationalUnitID: nil, projectID: testProject.id,
                maxVCPUs: 20, maxMemory: Int64(40.0 * 1024 * 1024 * 1024),
                maxStorage: Int64(200.0 * 1024 * 1024 * 1024), maxVMs: 10)
            try await projectQuota.save(on: app.db)

            // A bare org member: no project binding, so no `project:read` on the
            // project this quota scopes. The item route already refuses it via
            // `requireProjectMember`; before STR-116 the list handed it over
            // anyway, on org membership alone.
            let member = User(
                username: "quota-bare-member", email: "quota-member@example.com",
                displayName: "Bare Member", isSystemAdmin: false)
            try await member.save(on: app.db)
            _ = try await OrganizationMembershipStore.insert(
                userID: member.id!, organizationID: testOrganization.id!, on: app.db)
            let memberToken = try await member.generateAPIKey(on: app)

            try await app.test(.GET, "/api/quotas?level=project") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let quotas = try res.content.decode(PagedResponse<ResourceQuotaResponse>.self).items
                #expect(!quotas.contains { $0.name == "Hidden Project Quota" })
            }
        }
    }

    // MARK: - Update Quota Tests

    @Test("Update quota limits")
    func testUpdateQuotaLimits() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            let quota = ResourceQuota(
                name: "Update Test",
                organizationID: testOrganization.id,
                organizationalUnitID: nil,
                projectID: nil,
                maxVCPUs: 10,
                maxMemory: Int64(20.0 * 1024 * 1024 * 1024),
                maxStorage: Int64(100.0 * 1024 * 1024 * 1024),
                maxVMs: 5
            )
            try await quota.save(on: app.db)

            try await app.test(.PUT, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateResourceQuotaRequest(
                        name: "Updated Name",
                        maxVCPUs: 20,
                        maxMemoryGB: 40.0,
                        maxStorageGB: 200.0,
                        maxVMs: 10,
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: nil,
                        maxLoadBalancers: nil,
                        isEnabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ResourceQuotaResponse.self)
                #expect(response.name == "Updated Name")
                #expect(response.limits.maxVCPUs == 20)
                #expect(response.limits.maxMemoryGB == 40.0)
                #expect(response.limits.maxStorageGB == 200.0)
                #expect(response.limits.maxVMs == 10)
            }
        }
    }

    @Test("Cannot reduce quota below current usage")
    func testCannotReduceQuotaBelowUsage() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            let builder = TestDataBuilder(db: app.db)
            // 4 VMs × 2 vCPUs. The quota's own counters are left at zero, as they
            // are for any quota whose scope was already populated when it was
            // created — the guard has to measure, not read them (issue #742).
            for index in 0..<4 {
                _ = try await builder.createVM(name: "in-use-\(index)", project: testProject)
            }

            let quota = ResourceQuota(
                name: "In Use Quota",
                organizationID: testOrganization.id,
                organizationalUnitID: nil,
                projectID: nil,
                maxVCPUs: 10,
                maxMemory: Int64(20.0 * 1024 * 1024 * 1024),
                maxStorage: Int64(100.0 * 1024 * 1024 * 1024),
                maxVMs: 5
            )
            try await quota.save(on: app.db)

            try await app.test(.PUT, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateResourceQuotaRequest(
                        name: nil,
                        maxVCPUs: 5,  // Less than current usage of 8
                        maxMemoryGB: nil,
                        maxStorageGB: nil,
                        maxVMs: nil,
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: nil,
                        maxLoadBalancers: nil,
                        isEnabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // Same for the count limits, over the same never-backfilled counters.
            try await app.test(.PUT, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateResourceQuotaRequest(
                        name: nil,
                        maxVCPUs: nil,
                        maxMemoryGB: nil,
                        maxStorageGB: nil,
                        maxVMs: 3,  // Less than the 4 VMs in scope
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: nil,
                        maxLoadBalancers: nil,
                        isEnabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    /// A limit the request doesn't touch may already sit below real usage — a
    /// quota introduced over an oversized tenant, or one whose workloads grew
    /// while it was disabled. Now that the counters are refreshed to reality
    /// before saving, `validate()`'s reserved-vs-max check would have made such
    /// a quota permanently uneditable, including the very edits that fix it.
    @Test("An over-committed quota can still be raised, renamed and disabled")
    func testOverCommittedQuotaStaysEditable() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            let builder = TestDataBuilder(db: app.db)
            for index in 0..<3 {
                _ = try await builder.createVM(name: "over-\(index)", project: testProject)
            }

            // 6 vCPUs and 3 VMs in scope against a limit of 4 and 2.
            let quota = ResourceQuota(
                name: "Over Committed",
                organizationID: testOrganization.id,
                organizationalUnitID: nil,
                projectID: nil,
                maxVCPUs: 4,
                maxMemory: Int64(20.0 * 1024 * 1024 * 1024),
                maxStorage: Int64(100.0 * 1024 * 1024 * 1024),
                maxVMs: 2
            )
            try await quota.save(on: app.db)

            try await app.test(.PUT, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateResourceQuotaRequest(
                        name: "Over Committed (paused)",
                        maxVCPUs: nil,
                        maxMemoryGB: nil,
                        maxStorageGB: nil,
                        maxVMs: nil,
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: nil,
                        maxLoadBalancers: nil,
                        isEnabled: false
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ResourceQuotaResponse.self)
                #expect(response.name == "Over Committed (paused)")
                #expect(response.isEnabled == false)
                // The update healed the never-backfilled counters on the way past.
                #expect(response.usage.reservedVCPUs == 6)
                #expect(response.usage.vmCount == 3)
            }

            let reloaded = try await ResourceQuota.find(quota.id, on: app.db)
            #expect(reloaded?.reservedVCPUs == 6)
            #expect(reloaded?.vmCount == 3)
        }
    }

    @Test("Network backfill leaves an over-limit quota editable and floors touched limits")
    func testNetworkBackfillPreservesOverLimitRecovery() async throws {
        try await withQuotaTestApp { app, _, testOrganization, testProject, authToken in
            let builder = TestDataBuilder(db: app.db)
            _ = try await builder.createNetwork(
                name: "existing-a", project: testProject,
                subnet: "10.220.0.0/24", gateway: "10.220.0.1")
            _ = try await builder.createNetwork(
                name: "existing-b", project: testProject,
                subnet: "10.221.0.0/24", gateway: "10.221.0.1")

            let quota = ResourceQuota(
                name: "Legacy Network Quota",
                organizationID: testOrganization.id,
                maxVCPUs: 20,
                maxMemory: 40 * 1024 * 1024 * 1024,
                maxStorage: 200 * 1024 * 1024 * 1024,
                maxVMs: 10,
                maxNetworks: 1)
            try await quota.save(on: app.db)
            #expect(quota.networkCount == 0, "the legacy counter starts stale")

            try await BackfillNetworkQuotaAccounting().backfillQuotaCounters(on: app.db)
            let backfilled = try #require(try await ResourceQuota.find(quota.id, on: app.db))
            #expect(backfilled.networkCount == 2)

            // An untouched overage cannot make the row unsaveable: renaming is
            // one of the recovery operations an operator must retain.
            try await app.test(.PUT, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateResourceQuotaRequest(
                        name: "Legacy Network Quota (observed)",
                        maxVCPUs: nil,
                        maxMemoryGB: nil,
                        maxStorageGB: nil,
                        maxVMs: nil,
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: nil,
                        maxLoadBalancers: nil,
                        isEnabled: nil))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(ResourceQuotaResponse.self)
                #expect(response.usage.networkCount == 2)
            }

            let siteID = try #require(
                try await LogicalNetwork.all(on: app.db).first?.siteID)
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "blocked-after-backfill", subnet: "10.222.0.0/24",
                        projectId: try testProject.requireID(), siteId: siteID))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("Quota 'Legacy Network Quota (observed)' exceeded"))
            }

            try await app.test(.PUT, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateResourceQuotaRequest(
                        name: nil,
                        maxVCPUs: nil,
                        maxMemoryGB: nil,
                        maxStorageGB: nil,
                        maxVMs: nil,
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: 1,
                        maxLoadBalancers: nil,
                        isEnabled: nil))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("cannot be below current count (2)"))
            }

            try await app.test(.DELETE, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    // MARK: - Delete Quota Tests

    @Test("Delete unused quota")
    func testDeleteUnusedQuota() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            let quota = ResourceQuota(
                name: "Delete Test",
                organizationID: testOrganization.id,
                organizationalUnitID: nil,
                projectID: nil,
                maxVCPUs: 10,
                maxMemory: Int64(20.0 * 1024 * 1024 * 1024),
                maxStorage: Int64(100.0 * 1024 * 1024 * 1024),
                maxVMs: 5
            )
            try await quota.save(on: app.db)

            try await app.test(.DELETE, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let deletedQuota = try await ResourceQuota.find(quota.id, on: app.db)
            #expect(deletedQuota == nil)
        }
    }

    @Test("Cannot delete quota with usage")
    func testCannotDeleteQuotaWithUsage() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            let builder = TestDataBuilder(db: app.db)
            _ = try await builder.createVM(name: "guarded", project: testProject)

            // Counters left at zero, as they are for any quota created over an
            // already populated scope: the guard measures the scope (issue #742).
            let quota = ResourceQuota(
                name: "Used Quota",
                organizationID: testOrganization.id,
                organizationalUnitID: nil,
                projectID: nil,
                maxVCPUs: 10,
                maxMemory: Int64(20.0 * 1024 * 1024 * 1024),
                maxStorage: Int64(100.0 * 1024 * 1024 * 1024),
                maxVMs: 5
            )
            try await quota.save(on: app.db)

            try await app.test(.DELETE, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            let survivor = try await ResourceQuota.find(quota.id, on: app.db)
            #expect(survivor != nil)
        }
    }

    /// A sandbox reserves vCPUs and memory but no storage and no VM count, so
    /// it is the workload most easily missed by a guard that reads the wrong
    /// fields.
    @Test("Cannot delete a quota whose scope holds only sandboxes")
    func testCannotDeleteQuotaWithSandboxUsage() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            let builder = TestDataBuilder(db: app.db)
            _ = try await builder.createSandbox(name: "guarded-sbx", project: testProject)

            let quota = try await builder.createResourceQuota(
                name: "Sandbox Quota", organization: testOrganization)

            try await app.test(.DELETE, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    // MARK: - Quotas Created Over an Existing Tenant (issue #742)

    /// The rollout case: an admin starts enforcing limits on an organization
    /// that is already running workloads. Nothing creates or deletes a VM
    /// afterwards, so before this fix nothing ever resynced the counters off
    /// zero — and both admin-facing integrity guards read them.
    @Test("A quota created over live workloads guards its real usage")
    func testQuotaCreatedOverExistingWorkloadsGuardsRealUsage() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            let builder = TestDataBuilder(db: app.db)
            for index in 0..<5 {
                _ = try await builder.createVM(name: "existing-\(index)", project: testProject)
            }

            var quotaID: UUID?
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/quotas") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateResourceQuotaRequest(
                        name: "Rollout Quota",
                        maxVCPUs: 100,
                        maxMemoryGB: 200,
                        maxStorageGB: 1000,
                        maxVMs: 50,
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: nil,
                        maxLoadBalancers: nil,
                        environment: nil,
                        isEnabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ResourceQuotaResponse.self)
                quotaID = response.id
                // Create backfills the counters from the workloads already in scope.
                #expect(response.usage.reservedVCPUs == 10)
                #expect(response.usage.vmCount == 5)
            }

            let id = try #require(quotaID)

            // Lowering a limit under the real usage is rejected…
            try await app.test(.PUT, "/api/quotas/\(id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateResourceQuotaRequest(
                        name: nil,
                        maxVCPUs: 4,
                        maxMemoryGB: nil,
                        maxStorageGB: nil,
                        maxVMs: nil,
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: nil,
                        maxLoadBalancers: nil,
                        isEnabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // …and the quota guarding those workloads can't be deleted.
            try await app.test(.DELETE, "/api/quotas/\(id)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // The guards and the usage endpoint agree on the same fresh numbers.
            try await app.test(.GET, "/api/quotas/\(id)/usage") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let usage = try res.content.decode(QuotaUsageResponse.self)
                #expect(usage.actual.vcpus == 10)
                #expect(usage.actual.vms == 5)
                #expect(usage.reserved.vcpus == usage.actual.vcpus)
                #expect(usage.reserved.vms == usage.actual.vms)
            }
        }
    }

    /// The counters can also be stale *high* — a quota resynced before its
    /// workloads were deleted. Reading them then blocks edits and deletions
    /// that should be allowed, so the fix has to measure in both directions.
    @Test("Stale-high counters don't block a legitimate update or delete")
    func testStaleHighCountersDoNotBlockAdmin() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            let quota = ResourceQuota(
                name: "Stale Quota",
                organizationID: testOrganization.id,
                organizationalUnitID: nil,
                projectID: nil,
                maxVCPUs: 10,
                maxMemory: Int64(20.0 * 1024 * 1024 * 1024),
                maxStorage: Int64(100.0 * 1024 * 1024 * 1024),
                maxVMs: 5
            )
            // Left over from workloads that no longer exist.
            let staleQuota = quota.replacingCounters(reservedVCPUs: 8, vmCount: 4)
            try await staleQuota.save(on: app.db)

            try await app.test(.PUT, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateResourceQuotaRequest(
                        name: nil,
                        maxVCPUs: 2,
                        maxMemoryGB: nil,
                        maxStorageGB: nil,
                        maxVMs: 1,
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: nil,
                        maxLoadBalancers: nil,
                        isEnabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ResourceQuotaResponse.self)
                #expect(response.limits.maxVCPUs == 2)
                #expect(response.usage.reservedVCPUs == 0)
                #expect(response.usage.vmCount == 0)
            }

            try await app.test(.DELETE, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
        }
    }

    // Pins the issue #482 pre-cutover audit decision: a quota row with no
    // scope FK (corrupt data — every create path sets exactly one) is not a
    // shared resource. Before the fix, the scope-dispatch `if/else if` chains
    // fell through and allowed, so any authenticated user could read and
    // mutate such a row. Now only system admins can, for repair.
    @Test("Scopeless quota denies non-admin reads and writes, admits system admins")
    func testScopelessQuotaRequiresSystemAdmin() async throws {
        try await withQuotaTestApp { app, testUser, testOrganization, testProject, authToken in
            let quota = ResourceQuota(
                name: "Corrupt Scopeless Quota",
                organizationID: nil,
                organizationalUnitID: nil,
                projectID: nil,
                maxVCPUs: 10,
                maxMemory: Int64(20.0 * 1024 * 1024 * 1024),
                maxStorage: Int64(100.0 * 1024 * 1024 * 1024),
                maxVMs: 5
            )
            try await quota.save(on: app.db)

            // The org-admin (but not system-admin) caller is denied everywhere.
            try await app.test(.GET, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            try await app.test(.PUT, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateResourceQuotaRequest(
                        name: "Hijacked",
                        maxVCPUs: nil,
                        maxMemoryGB: nil,
                        maxStorageGB: nil,
                        maxVMs: nil,
                        maxSandboxes: nil,
                        maxVolumes: nil,
                        maxNetworks: nil,
                        maxLoadBalancers: nil,
                        isEnabled: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            try await app.test(.DELETE, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            // A system admin can still inspect and remove the corrupt row.
            let admin = User(
                username: "quotasysadmin",
                email: "quotasysadmin@example.com",
                displayName: "Quota Sysadmin",
                isSystemAdmin: true
            )
            try await admin.save(on: app.db)
            let adminToken = try await admin.generateAPIKey(on: app)

            try await app.test(.GET, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            try await app.test(.DELETE, "/api/quotas/\(quota.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
        }
    }
}
