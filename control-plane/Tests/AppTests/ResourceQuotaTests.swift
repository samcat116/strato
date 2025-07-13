import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

@Suite("Resource Quota API Tests")
final class ResourceQuotaTests {
    var app: Application!
    var testUser: User!
    var testOrganization: Organization!
    var testProject: Project!
    var authToken: String!
    
    init() async throws {
        self.app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoRevert()
        try await app.autoMigrate()
        
        // Create test user and organization
        testUser = User(
            username: "testuser",
            email: "test@example.com",
            displayName: "Test User",
            isSystemAdmin: false
        )
        try await testUser.save(on: app.db)
        
        testOrganization = Organization(
            name: "Test Organization",
            description: "Test organization for unit tests"
        )
        try await testOrganization.save(on: app.db)
        
        // Create test project
        testProject = Project(
            name: "Test Project",
            description: "Test project",
            organizationID: testOrganization.id,
            path: ""
        )
        try await testProject.save(on: app.db)
        testProject.path = try await testProject.buildPath(on: app.db)
        try await testProject.save(on: app.db)
        
        // Add user to organization as admin
        let userOrg = UserOrganization(
            userID: testUser.id!,
            organizationID: testOrganization.id!,
            role: "admin"
        )
        try await userOrg.save(on: app.db)
        
        authToken = try await testUser.generateAPIKey(on: app.db)
    }
    
    deinit {
        let application = app
        Task {
            try? await application?.asyncShutdown()
        }
    }
    
    // MARK: - Create Quota Tests
    
    @Test("Create organization-level quota")
    func testCreateOrganizationQuota() async throws {
        try await app.test(.POST, "/organizations/\(testOrganization.id!)/quotas") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            try req.content.encode(CreateResourceQuotaRequest(
                name: "Org Quota",
                maxVCPUs: 100,
                maxMemoryGB: 200,
                maxStorageGB: 1000,
                maxVMs: 50,
                maxNetworks: nil,
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
    
    @Test("Create project-level quota")
    func testCreateProjectQuota() async throws {
        try await app.test(.POST, "/projects/\(testProject.id!)/quotas") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            try req.content.encode(CreateResourceQuotaRequest(
                name: "Project Quota",
                maxVCPUs: 20,
                maxMemoryGB: 40,
                maxStorageGB: 200,
                maxVMs: 10,
                maxNetworks: nil,
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
    
    @Test("Create environment-specific quota")
    func testCreateEnvironmentQuota() async throws {
        try await app.test(.POST, "/projects/\(testProject.id!)/quotas") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            try req.content.encode(CreateResourceQuotaRequest(
                name: "Production Quota",
                maxVCPUs: 50,
                maxMemoryGB: 100,
                maxStorageGB: 500,
                maxVMs: 25,
                maxNetworks: nil,
                environment: "production",
                isEnabled: nil
            ))
        } afterResponse: { res in
            #expect(res.status == .ok)
            
            let response = try res.content.decode(ResourceQuotaResponse.self)
            #expect(response.environment == "production")
            #expect(response.entityType == "project") // Environment quota is still under project
        }
    }
    
    // MARK: - Usage Tracking Tests
    
    @Test("Track quota usage")
    func testQuotaUsageTracking() async throws {
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
        quota.reservedVCPUs = 4
        quota.reservedMemory = Int64(8.0 * 1024 * 1024 * 1024)
        quota.reservedStorage = Int64(40.0 * 1024 * 1024 * 1024)
        quota.vmCount = 2
        try await quota.save(on: app.db)
        
        // Get quota with usage
        try await app.test(.GET, "/quotas/\(quota.id!)") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
        } afterResponse: { res in
            #expect(res.status == .ok)
            
            let response = try res.content.decode(ResourceQuotaResponse.self)
            #expect(response.usage.reservedVCPUs == 4)
            #expect(response.usage.reservedMemoryGB == 8.0)
            #expect(response.usage.reservedStorageGB == 40.0)
            #expect(response.usage.vmCount == 2)
            
            // Check utilization percentages
            #expect(response.utilization.cpuPercent == 40.0) // 4/10 * 100
            #expect(response.utilization.memoryPercent == 40.0) // 8/20 * 100
            #expect(response.utilization.storagePercent == 40.0) // 40/100 * 100
            #expect(response.utilization.vmPercent == 40.0) // 2/5 * 100
        }
    }
    
    @Test("Quota validation - exceeding limits")
    func testQuotaExceedsLimits() async throws {
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
    
    // MARK: - Hierarchy Tests
    
    @Test("List quotas by level")
    func testListQuotasByLevel() async throws {
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
        try await app.test(.GET, "/quotas?level=organization") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
        } afterResponse: { res in
            #expect(res.status == .ok)
            
            let quotas = try res.content.decode([ResourceQuotaResponse].self)
            #expect(quotas.allSatisfy { $0.entityType == "organization" })
        }
        
        // List project quotas
        try await app.test(.GET, "/quotas?level=project") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
        } afterResponse: { res in
            #expect(res.status == .ok)
            
            let quotas = try res.content.decode([ResourceQuotaResponse].self)
            #expect(quotas.allSatisfy { $0.entityType == "project" })
        }
    }
    
    // MARK: - Update Quota Tests
    
    @Test("Update quota limits")
    func testUpdateQuotaLimits() async throws {
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
        
        try await app.test(.PUT, "/quotas/\(quota.id!)") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            try req.content.encode(UpdateResourceQuotaRequest(
                name: "Updated Name",
                maxVCPUs: 20,
                maxMemoryGB: 40.0,
                maxStorageGB: 200.0,
                maxVMs: 10,
                maxNetworks: nil,
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
    
    @Test("Cannot reduce quota below current usage")
    func testCannotReduceQuotaBelowUsage() async throws {
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
        quota.reservedVCPUs = 8
        try await quota.save(on: app.db)
        
        try await app.test(.PUT, "/quotas/\(quota.id!)") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            try req.content.encode(UpdateResourceQuotaRequest(
                name: nil,
                maxVCPUs: 5,  // Less than current usage of 8
                maxMemoryGB: nil,
                maxStorageGB: nil,
                maxVMs: nil,
                maxNetworks: nil,
                isEnabled: nil
            ))
        } afterResponse: { res in
            #expect(res.status == .badRequest)
        }
    }
    
    // MARK: - Delete Quota Tests
    
    @Test("Delete unused quota")
    func testDeleteUnusedQuota() async throws {
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
        
        try await app.test(.DELETE, "/quotas/\(quota.id!)") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
        } afterResponse: { res in
            #expect(res.status == .noContent)
        }
        
        let deletedQuota = try await ResourceQuota.find(quota.id, on: app.db)
        #expect(deletedQuota == nil)
    }
    
    @Test("Cannot delete quota with usage")
    func testCannotDeleteQuotaWithUsage() async throws {
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
        quota.reservedVCPUs = 2
        quota.vmCount = 1
        try await quota.save(on: app.db)
        
        try await app.test(.DELETE, "/quotas/\(quota.id!)") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
        } afterResponse: { res in
            #expect(res.status == .conflict)
        }
    }
}