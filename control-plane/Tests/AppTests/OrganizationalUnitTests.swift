import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

@Suite("Organizational Unit API Tests", .serialized)
final class OrganizationalUnitTests {
    var app: Application!
    var testUser: User!
    var testOrganization: Organization!
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
        if let app = app {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                try? await app.asyncShutdown()
                try? await Task.sleep(for: .milliseconds(100))
                app.cleanupTestDatabase()
                semaphore.signal()
            }
            semaphore.wait()
        }
    }

    // MARK: - Create OU Tests

    @Test("Create top-level OU")
    func testCreateTopLevelOU() async throws {
        try await app.test(.POST, "/organizations/\(testOrganization.id!)/ous") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            try req.content.encode(CreateOrganizationalUnitRequest(
                name: "Engineering",
                description: "Engineering department"
            ))
        } afterResponse: { res in
            #expect(res.status == .ok)

            let response = try res.content.decode(OrganizationalUnitResponse.self)
            #expect(response.name == "Engineering")
            #expect(response.description == "Engineering department")
            #expect(response.organizationId == testOrganization.id)
            #expect(response.parentOuId == nil)
            #expect(response.depth == 0)
        }
    }

    @Test("Create nested OU")
    func testCreateNestedOU() async throws {
        // Create parent OU
        let parentOU = OrganizationalUnit(
            name: "Engineering",
            description: "Engineering department",
            organizationID: testOrganization.id!,
            path: "",
            depth: 0
        )
        try await parentOU.save(on: app.db)
        parentOU.path = try await parentOU.buildPath(on: app.db)
        try await parentOU.save(on: app.db)

        // Create nested OU
        try await app.test(.POST, "/organizations/\(testOrganization.id!)/ous") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            try req.content.encode(CreateOrganizationalUnitRequest(
                name: "Backend",
                description: "Backend team",
                parentOuId: parentOU.id
            ))
        } afterResponse: { res in
            #expect(res.status == .ok)

            let response = try res.content.decode(OrganizationalUnitResponse.self)
            #expect(response.name == "Backend")
            #expect(response.parentOuId == parentOU.id)
            #expect(response.depth == 1)
        }
    }

    @Test("Create OU with duplicate name in same scope fails")
    func testCreateDuplicateOU() async throws {
        // Create first OU
        let firstOU = OrganizationalUnit(
            name: "Duplicate",
            description: "First OU",
            organizationID: testOrganization.id!,
            path: "",
            depth: 0
        )
        try await firstOU.save(on: app.db)

        // Try to create second OU with same name
        try await app.test(.POST, "/organizations/\(testOrganization.id!)/ous") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            try req.content.encode(CreateOrganizationalUnitRequest(
                name: "Duplicate",
                description: "Second OU"
            ))
        } afterResponse: { res in
            #expect(res.status == .conflict)
        }
    }

    // MARK: - List OUs Tests

    @Test("List top-level OUs")
    func testListTopLevelOUs() async throws {
        // Create test OUs
        let ou1 = OrganizationalUnit(
            name: "Engineering",
            description: "Engineering dept",
            organizationID: testOrganization.id!,
            path: "",
            depth: 0
        )
        try await ou1.save(on: app.db)

        let ou2 = OrganizationalUnit(
            name: "Sales",
            description: "Sales dept",
            organizationID: testOrganization.id!,
            path: "",
            depth: 0
        )
        try await ou2.save(on: app.db)

        // Create nested OU (should not appear in top-level list)
        let nestedOU = OrganizationalUnit(
            name: "Backend",
            description: "Backend team",
            organizationID: testOrganization.id!,
            parentOUID: ou1.id,
            path: "",
            depth: 1
        )
        try await nestedOU.save(on: app.db)

        try await app.test(.GET, "/organizations/\(testOrganization.id!)/ous") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
        } afterResponse: { res in
            #expect(res.status == .ok)

            let ous = try res.content.decode([OrganizationalUnitResponse].self)
            #expect(ous.count == 2)
            #expect(ous.contains { $0.name == "Engineering" })
            #expect(ous.contains { $0.name == "Sales" })
            #expect(!ous.contains { $0.name == "Backend" })
        }
    }

    // MARK: - Hierarchy Operations Tests

    @Test("Get OU tree")
    func testGetOUTree() async throws {
        // Create OU hierarchy
        let rootOU = OrganizationalUnit(
            name: "Engineering",
            description: "Engineering dept",
            organizationID: testOrganization.id!,
            path: "",
            depth: 0
        )
        try await rootOU.save(on: app.db)
        rootOU.path = try await rootOU.buildPath(on: app.db)
        try await rootOU.save(on: app.db)

        let childOU1 = OrganizationalUnit(
            name: "Backend",
            description: "Backend team",
            organizationID: testOrganization.id!,
            parentOUID: rootOU.id,
            path: "",
            depth: 1
        )
        try await childOU1.save(on: app.db)
        childOU1.path = try await childOU1.buildPath(on: app.db)
        try await childOU1.save(on: app.db)

        let childOU2 = OrganizationalUnit(
            name: "Frontend",
            description: "Frontend team",
            organizationID: testOrganization.id!,
            parentOUID: rootOU.id,
            path: "",
            depth: 1
        )
        try await childOU2.save(on: app.db)
        childOU2.path = try await childOU2.buildPath(on: app.db)
        try await childOU2.save(on: app.db)

        try await app.test(.GET, "/organizations/\(testOrganization.id!)/ous/\(rootOU.id!)/tree") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
        } afterResponse: { res in
            #expect(res.status == .ok)

            let tree = try res.content.decode(OrganizationalUnitTreeResponse.self)
            #expect(tree.name == "Engineering")
            #expect(tree.children.count == 2)
            #expect(tree.children.contains { $0.name == "Backend" })
            #expect(tree.children.contains { $0.name == "Frontend" })
        }
    }

    @Test("Move OU to different parent")
    func testMoveOU() async throws {
        // Create OUs
        let ou1 = OrganizationalUnit(
            name: "Department A",
            description: "Dept A",
            organizationID: testOrganization.id!,
            path: "",
            depth: 0
        )
        try await ou1.save(on: app.db)
        ou1.path = try await ou1.buildPath(on: app.db)
        try await ou1.save(on: app.db)

        let ou2 = OrganizationalUnit(
            name: "Department B",
            description: "Dept B",
            organizationID: testOrganization.id!,
            path: "",
            depth: 0
        )
        try await ou2.save(on: app.db)
        ou2.path = try await ou2.buildPath(on: app.db)
        try await ou2.save(on: app.db)

        let childOU = OrganizationalUnit(
            name: "Team X",
            description: "Team X",
            organizationID: testOrganization.id!,
            parentOUID: ou1.id,
            path: "",
            depth: 1
        )
        try await childOU.save(on: app.db)
        childOU.path = try await childOU.buildPath(on: app.db)
        try await childOU.save(on: app.db)

        // Move childOU from ou1 to ou2
        try await app.test(.POST, "/organizations/\(testOrganization.id!)/ous/\(childOU.id!)/move") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            try req.content.encode(MoveOrganizationalUnitRequest(
                newParentOuId: ou2.id
            ))
        } afterResponse: { res in
            #expect(res.status == .ok)

            let response = try res.content.decode(OrganizationalUnitResponse.self)
            #expect(response.parentOuId == ou2.id)
            #expect(response.path.contains(ou2.id!.uuidString))
        }
    }

    // MARK: - Update OU Tests

    @Test("Update OU details")
    func testUpdateOU() async throws {
        let ou = OrganizationalUnit(
            name: "Original Name",
            description: "Original description",
            organizationID: testOrganization.id!,
            path: "",
            depth: 0
        )
        try await ou.save(on: app.db)

        try await app.test(.PUT, "/organizations/\(testOrganization.id!)/ous/\(ou.id!)") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            try req.content.encode(UpdateOrganizationalUnitRequest(
                name: "Updated Name",
                description: "Updated description"
            ))
        } afterResponse: { res in
            #expect(res.status == .ok)

            let response = try res.content.decode(OrganizationalUnitResponse.self)
            #expect(response.name == "Updated Name")
            #expect(response.description == "Updated description")
        }
    }

    // MARK: - Delete OU Tests

    @Test("Delete empty OU")
    func testDeleteEmptyOU() async throws {
        let ou = OrganizationalUnit(
            name: "Delete Test",
            description: "OU to be deleted",
            organizationID: testOrganization.id!,
            path: "",
            depth: 0
        )
        try await ou.save(on: app.db)

        try await app.test(.DELETE, "/organizations/\(testOrganization.id!)/ous/\(ou.id!)") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
        } afterResponse: { res in
            #expect(res.status == .noContent)
        }

        let deletedOU = try await OrganizationalUnit.find(ou.id, on: app.db)
        #expect(deletedOU == nil)
    }

    @Test("Delete OU with children fails")
    func testDeleteOUWithChildren() async throws {
        let parentOU = OrganizationalUnit(
            name: "Parent",
            description: "Parent OU",
            organizationID: testOrganization.id!,
            path: "",
            depth: 0
        )
        try await parentOU.save(on: app.db)

        let childOU = OrganizationalUnit(
            name: "Child",
            description: "Child OU",
            organizationID: testOrganization.id!,
            parentOUID: parentOU.id,
            path: "",
            depth: 1
        )
        try await childOU.save(on: app.db)

        try await app.test(.DELETE, "/organizations/\(testOrganization.id!)/ous/\(parentOU.id!)") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
        } afterResponse: { res in
            #expect(res.status == .conflict)
        }
    }
}
