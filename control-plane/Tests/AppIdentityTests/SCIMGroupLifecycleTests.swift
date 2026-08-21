import Foundation
import SwiftSCIM
import Testing

import AppTestSupport
@testable import App

@Suite("SCIM group lifecycle", .serialized)
final class SCIMGroupLifecycleTests: BaseTestCase {
    @Test("create, replace, patch, and delete preserve SCIM mappings and membership intent")
    func lifecycle() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(app: app)
            let organization = try await builder.createOrganization(name: "SCIM Group Organization")
            let member = try await builder.createUser(
                username: "scim-group-member",
                email: "scim-group-member@example.com",
                displayName: "SCIM Group Member"
            )
            try await builder.addUserToOrganization(user: member, organization: organization)
            let handler = GroupSCIMHandler(
                groups: app.groupsPersistence,
                externalIDs: app.scimExternalIDsPersistence,
                organizationID: organization.id!,
                logger: app.logger
            )
            let context = makeContext()

            let created = try await handler.create(
                SCIMGroup(
                    externalId: "directory-group-1",
                    displayName: "Directory Team",
                    members: [GroupMember(value: member.id!.uuidString)]
                ),
                context: context
            )
            let groupID = try #require(created.id.flatMap(UUID.init(uuidString:)))
            #expect(created.externalId == "directory-group-1")
            #expect(created.members?.map(\.value) == [member.id!.uuidString])
            #expect(try await app.groupsPersistence.group(id: groupID)?.scimProvisioned == true)

            let replaced = try await handler.replace(
                id: groupID.uuidString,
                with: SCIMGroup(
                    externalId: "directory-group-1",
                    displayName: "Renamed Directory Team"
                ),
                context: context
            )
            #expect(replaced.displayName == "Renamed Directory Team")
            #expect(replaced.members == nil)

            let patched = try await handler.patch(
                id: groupID.uuidString,
                operations: [
                    .replace(path: "displayName", stringValue: "Patched Directory Team"),
                    .add(
                        path: "members",
                        value: .array([.object(["value": .string(member.id!.uuidString)])])
                    ),
                ],
                context: context
            )
            #expect(patched.displayName == "Patched Directory Team")
            #expect(patched.members?.map(\.value) == [member.id!.uuidString])

            try await handler.delete(id: groupID.uuidString, context: context)
            #expect(try await app.groupsPersistence.group(id: groupID) == nil)
            #expect(
                try await app.scimExternalIDsPersistence.internalID(
                    externalID: "directory-group-1",
                    resourceType: .group,
                    organizationID: organization.id!
                ) == nil
            )
        }
    }

    @Test("lookups do not cross organization boundaries")
    func organizationScope() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(app: app)
            let owner = try await builder.createOrganization(name: "SCIM Group Owner")
            let other = try await builder.createOrganization(name: "SCIM Group Other")
            let group = try await builder.createGroup(
                name: "Owner Only",
                description: "",
                organization: owner
            )
            let handler = GroupSCIMHandler(
                groups: app.groupsPersistence,
                externalIDs: app.scimExternalIDsPersistence,
                organizationID: other.id!,
                logger: app.logger
            )

            do {
                _ = try await handler.get(id: group.requireID().uuidString, context: makeContext())
                Issue.record("Expected an organization-scoped SCIM lookup to fail")
            } catch is SCIMServerError {
                // Expected: callers must not learn about another organization's group.
            }
        }
    }

    private func makeContext() -> SCIMRequestContext {
        SCIMRequestContext(
            auth: .anonymous,
            baseURL: URL(string: "http://localhost:8080/scim/v2")!,
            request: SCIMRequest(method: .GET, path: "/Groups")
        )
    }
}
