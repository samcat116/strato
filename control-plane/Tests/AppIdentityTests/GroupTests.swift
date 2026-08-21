import Testing
import Vapor
import VaporTesting
import AppTestSupport
@testable import App

@Suite("Group API Tests", .serialized)
final class GroupTests: BaseTestCase {

    // MARK: - Create Group Tests

    @Test("Create group successfully")
    func testCreateGroup() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)

            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateGroupRequest(
                        name: "Test Group",
                        description: "A test group"
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(GroupResponse.self)
                #expect(response.name == "Test Group")
                #expect(response.description == "A test group")
                #expect(response.organizationId == testOrganization.id)
                #expect(response.memberCount == 0)
            }
        }
    }

    @Test("Create group with duplicate name fails")
    func testCreateDuplicateGroup() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)

            let builder = TestDataBuilder(app: app)
            _ = try await builder.createGroup(
                name: "Duplicate Group",
                description: "First group",
                organization: testOrganization
            )

            // Try to create second group with same name
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    CreateGroupRequest(
                        name: "Duplicate Group",
                        description: "Second group"
                    ))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("Create group without admin access fails")
    func testCreateGroupWithoutAdminAccess() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)

            // Create member user: a bare "member" with no admin binding, so
            // the Cedar evaluator denies group creation.
            let memberUser = User(
                username: "memberuser",
                email: "member@example.com",
                displayName: "Member User"
            )
            try await memberUser.save(on: app.testPostgres)

            _ = try await OrganizationMembershipStore.insert(
                userID: memberUser.id!,
                organizationID: testOrganization.id!,
                on: app.testPostgres
            )

            let memberToken = try await memberUser.generateAPIKey(on: app)

            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
                try req.content.encode(
                    CreateGroupRequest(
                        name: "Unauthorized Group",
                        description: "Should fail"
                    ))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - List Groups Tests

    @Test("List groups in organization")
    func testListGroups() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)

            let builder = TestDataBuilder(app: app)
            _ = try await builder.createGroup(
                name: "Group A", description: "First group", organization: testOrganization)
            _ = try await builder.createGroup(
                name: "Group B", description: "Second group", organization: testOrganization)

            try await app.test(.GET, "/api/organizations/\(testOrganization.id!)/groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let groups = try res.content.decode([GroupResponse].self)
                #expect(groups.count == 2)
                #expect(groups.contains { $0.name == "Group A" })
                #expect(groups.contains { $0.name == "Group B" })
            }
        }
    }

    // MARK: - Group Membership Tests

    @Test("Add members to group")
    func testAddMembersToGroup() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)

            let builder = TestDataBuilder(app: app)
            let group = try await builder.createGroup(
                name: "Member Test Group",
                description: "Group for membership testing",
                organization: testOrganization
            )

            // Create test users
            let user1 = User(
                username: "user1",
                email: "user1@example.com",
                displayName: "User 1"
            )
            try await user1.save(on: app.testPostgres)

            let user2 = User(
                username: "user2",
                email: "user2@example.com",
                displayName: "User 2"
            )
            try await user2.save(on: app.testPostgres)

            // Add users to organization
            for user in [user1, user2] {
                _ = try await OrganizationMembershipStore.insert(
                    userID: user.id!,
                    organizationID: testOrganization.id!,
                    on: app.testPostgres
                )
            }

            // Add members to group
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/groups/\(group.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    AddGroupMemberRequest(
                        userIds: [user1.id!, user2.id!]
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // Verify members were added
            let memberCount = try await app.groupsPersistence.members(groupID: group.requireID()).count
            #expect(memberCount == 2)
        }
    }

    @Test("Remove member from group")
    func testRemoveMemberFromGroup() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)

            let builder = TestDataBuilder(app: app)
            let group = try await builder.createGroup(
                name: "Remove Test Group",
                description: "Group for removal testing",
                organization: testOrganization
            )

            // Create and add test user
            let user = User(
                username: "removeuser",
                email: "remove@example.com",
                displayName: "Remove User"
            )
            try await user.save(on: app.testPostgres)

            _ = try await OrganizationMembershipStore.insert(
                userID: user.id!,
                organizationID: testOrganization.id!,
                on: app.testPostgres
            )

            // Add user to group
            try await builder.addUserToGroup(user: user, group: group)

            // Remove member from group
            try await app.test(
                .DELETE, "/api/organizations/\(testOrganization.id!)/groups/\(group.id!)/members/\(user.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // Verify member was removed
            let memberCount = try await app.groupsPersistence.members(groupID: group.requireID()).count
            #expect(memberCount == 0)
        }
    }

    // MARK: - Update Group Tests

    @Test("Update group details")
    func testUpdateGroup() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)

            let group = try await TestDataBuilder(app: app).createGroup(
                name: "Original Name",
                description: "Original description",
                organization: testOrganization
            )

            try await app.test(.PUT, "/api/organizations/\(testOrganization.id!)/groups/\(group.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateGroupRequest(
                        name: "Updated Name",
                        description: "Updated description"
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(GroupResponse.self)
                #expect(response.name == "Updated Name")
                #expect(response.description == "Updated description")
            }
        }
    }

    // MARK: - Delete Group Tests

    @Test("Delete group")
    func testDeleteGroup() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)

            let group = try await TestDataBuilder(app: app).createGroup(
                name: "Delete Test Group",
                description: "Group to be deleted",
                organization: testOrganization
            )

            try await app.test(.DELETE, "/api/organizations/\(testOrganization.id!)/groups/\(group.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            // Verify group was deleted
            let deletedGroup = try await app.groupsPersistence.group(id: group.requireID())
            #expect(deletedGroup == nil)
        }
    }

    @Test("A group addressed through another organization remains a bad request")
    func testWrongOrganizationKeepsCompatibilityStatus() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app)
            let builder = TestDataBuilder(app: app)
            let group = try await builder.createGroup(
                name: "Scoped Group",
                description: "Must stay in its organization",
                organization: testOrganization
            )
            let otherOrganization = try await builder.createOrganization(name: "Other Organization")
            try await builder.addUserToOrganization(
                user: testUser,
                organization: otherOrganization,
                role: "admin"
            )

            try await app.test(
                .GET,
                "/api/organizations/\(otherOrganization.id!)/groups/\(group.id!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { response in
                #expect(response.status == .badRequest)
            }
        }
    }
}
