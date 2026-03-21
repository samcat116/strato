import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

@Suite("Group API Tests", .serialized)
final class GroupTests: BaseTestCase {

    // MARK: - Create Group Tests

    @Test("Create group successfully")
    func testCreateGroup() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(CreateGroupRequest(
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
            try await setupCommonTestData(on: app.db)

            // Create first group
            let firstGroup = Group(
                name: "Duplicate Group",
                description: "First group",
                organizationID: testOrganization.id!
            )
            try await firstGroup.save(on: app.db)

            // Try to create second group with same name
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(CreateGroupRequest(
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
            try await setupCommonTestData(on: app.db)

            // Create member user
            let memberUser = User(
                username: "memberuser",
                email: "member@example.com",
                displayName: "Member User"
            )
            try await memberUser.save(on: app.db)

            let memberOrg = UserOrganization(
                userID: memberUser.id!,
                organizationID: testOrganization.id!,
                role: "member"
            )
            try await memberOrg.save(on: app.db)

            let memberToken = try await memberUser.generateAPIKey(on: app.db)

            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
                try req.content.encode(CreateGroupRequest(
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
            try await setupCommonTestData(on: app.db)

            // Create test groups
            let group1 = Group(
                name: "Group A",
                description: "First group",
                organizationID: testOrganization.id!
            )
            try await group1.save(on: app.db)

            let group2 = Group(
                name: "Group B",
                description: "Second group",
                organizationID: testOrganization.id!
            )
            try await group2.save(on: app.db)

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
            try await setupCommonTestData(on: app.db)

            let group = Group(
                name: "Member Test Group",
                description: "Group for membership testing",
                organizationID: testOrganization.id!
            )
            try await group.save(on: app.db)

            // Create test users
            let user1 = User(
                username: "user1",
                email: "user1@example.com",
                displayName: "User 1"
            )
            try await user1.save(on: app.db)

            let user2 = User(
                username: "user2",
                email: "user2@example.com",
                displayName: "User 2"
            )
            try await user2.save(on: app.db)

            // Add users to organization
            for user in [user1, user2] {
                let userOrg = UserOrganization(
                    userID: user.id!,
                    organizationID: testOrganization.id!,
                    role: "member"
                )
                try await userOrg.save(on: app.db)
            }

            // Add members to group
            try await app.test(.POST, "/api/organizations/\(testOrganization.id!)/groups/\(group.id!)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(AddGroupMemberRequest(
                    userIds: [user1.id!, user2.id!]
                ))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // Verify members were added
            let memberCount = try await group.getMemberCount(on: app.db)
            #expect(memberCount == 2)
        }
    }

    @Test("Remove member from group")
    func testRemoveMemberFromGroup() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            let group = Group(
                name: "Remove Test Group",
                description: "Group for removal testing",
                organizationID: testOrganization.id!
            )
            try await group.save(on: app.db)

            // Create and add test user
            let user = User(
                username: "removeuser",
                email: "remove@example.com",
                displayName: "Remove User"
            )
            try await user.save(on: app.db)

            let userOrg = UserOrganization(
                userID: user.id!,
                organizationID: testOrganization.id!,
                role: "member"
            )
            try await userOrg.save(on: app.db)

            // Add user to group
            try await group.addMember(user.id!, on: app.db)

            // Remove member from group
            try await app.test(.DELETE, "/api/organizations/\(testOrganization.id!)/groups/\(group.id!)/members/\(user.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // Verify member was removed
            let memberCount = try await group.getMemberCount(on: app.db)
            #expect(memberCount == 0)
        }
    }

    // MARK: - Update Group Tests

    @Test("Update group details")
    func testUpdateGroup() async throws {
        try await withApp { app in
            try await setupCommonTestData(on: app.db)

            let group = Group(
                name: "Original Name",
                description: "Original description",
                organizationID: testOrganization.id!
            )
            try await group.save(on: app.db)

            try await app.test(.PUT, "/api/organizations/\(testOrganization.id!)/groups/\(group.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(UpdateGroupRequest(
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
            try await setupCommonTestData(on: app.db)

            let group = Group(
                name: "Delete Test Group",
                description: "Group to be deleted",
                organizationID: testOrganization.id!
            )
            try await group.save(on: app.db)

            try await app.test(.DELETE, "/api/organizations/\(testOrganization.id!)/groups/\(group.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            // Verify group was deleted
            let deletedGroup = try await Group.find(group.id, on: app.db)
            #expect(deletedGroup == nil)
        }
    }
}
