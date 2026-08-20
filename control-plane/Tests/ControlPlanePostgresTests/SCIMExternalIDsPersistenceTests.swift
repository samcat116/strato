import Foundation
import Testing

@testable import ControlPlanePostgres

@Suite("Native SCIM external-ID persistence", .serialized)
struct SCIMExternalIDsPersistenceTests {
    @Test("assignments round-trip within organization and resource-type scope")
    func roundTripAndScope() async throws {
        try await withSCIMExternalIDDatabase { _, externalIDs in
            let organizationID = UUID()
            let internalID = UUID()
            let created = try await externalIDs.assign(
                externalID: "upstream-user-1",
                to: internalID,
                resourceType: .user,
                organizationID: organizationID
            )

            #expect(created.organizationID == organizationID)
            #expect(created.resourceType == .user)
            #expect(created.externalID == "upstream-user-1")
            #expect(created.internalID == internalID)
            #expect(created.createdAt != nil)
            #expect(created.updatedAt != nil)
            #expect(
                try await externalIDs.internalID(
                    externalID: "upstream-user-1",
                    resourceType: .user,
                    organizationID: organizationID
                ) == internalID
            )
            #expect(
                try await externalIDs.externalID(
                    internalID: internalID,
                    resourceType: .user,
                    organizationID: organizationID
                ) == "upstream-user-1"
            )
            #expect(
                try await externalIDs.internalID(
                    externalID: "upstream-user-1",
                    resourceType: .group,
                    organizationID: organizationID
                ) == nil
            )
            #expect(
                try await externalIDs.internalID(
                    externalID: "upstream-user-1",
                    resourceType: .user,
                    organizationID: UUID()
                ) == nil
            )
        }
    }

    @Test("reassignment preserves the durable mapping row")
    func reassignment() async throws {
        try await withSCIMExternalIDDatabase { _, externalIDs in
            let organizationID = UUID()
            let original = try await externalIDs.assign(
                externalID: "upstream-group-1",
                to: UUID(),
                resourceType: .group,
                organizationID: organizationID
            )
            let replacementInternalID = UUID()
            let replaced = try await externalIDs.assign(
                externalID: original.externalID,
                to: replacementInternalID,
                resourceType: .group,
                organizationID: organizationID
            )

            #expect(replaced.id == original.id)
            #expect(replaced.internalID == replacementInternalID)
            #expect(
                try await externalIDs.internalID(
                    externalID: original.externalID,
                    resourceType: .group,
                    organizationID: organizationID
                ) == replacementInternalID
            )
        }
    }

    @Test("removal clears every historical alias for an internal resource")
    func removeAliases() async throws {
        try await withSCIMExternalIDDatabase { _, externalIDs in
            let organizationID = UUID()
            let internalID = UUID()
            _ = try await externalIDs.assign(
                externalID: "alias-a",
                to: internalID,
                resourceType: .user,
                organizationID: organizationID
            )
            _ = try await externalIDs.assign(
                externalID: "alias-b",
                to: internalID,
                resourceType: .user,
                organizationID: organizationID
            )

            let removed = try await externalIDs.remove(
                internalID: internalID,
                resourceType: .user,
                organizationID: organizationID
            )

            #expect(removed.count == 2)
            #expect(
                try await externalIDs.internalID(
                    externalID: "alias-a",
                    resourceType: .user,
                    organizationID: organizationID
                ) == nil
            )
            #expect(
                try await externalIDs.internalID(
                    externalID: "alias-b",
                    resourceType: .user,
                    organizationID: organizationID
                ) == nil
            )
        }
    }

    @Test("concurrent assignment converges on one mapping row")
    func concurrentAssignment() async throws {
        try await withSCIMExternalIDDatabase(maximumConnections: 4) { _, externalIDs in
            let organizationID = UUID()
            let candidates = (0..<8).map { _ in UUID() }
            let snapshots = try await withThrowingTaskGroup(of: SCIMExternalIDSnapshot.self) { group in
                for internalID in candidates {
                    group.addTask {
                        try await externalIDs.assign(
                            externalID: "shared-upstream-id",
                            to: internalID,
                            resourceType: .user,
                            organizationID: organizationID
                        )
                    }
                }
                var values: [SCIMExternalIDSnapshot] = []
                for try await snapshot in group { values.append(snapshot) }
                return values
            }

            #expect(snapshots.count == candidates.count)
            #expect(Set(snapshots.map(\.id)).count == 1)
            let stored = try #require(
                try await externalIDs.internalID(
                    externalID: "shared-upstream-id",
                    resourceType: .user,
                    organizationID: organizationID
                )
            )
            #expect(candidates.contains(stored))
        }
    }

    private func withSCIMExternalIDDatabase(
        maximumConnections: Int = 1,
        _ test: (PostgresDatabase, SCIMExternalIDsPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase(maximumConnections: maximumConnections) { database in
            try await database.withSession(operation: "test.scim_external_ids.schema") { session in
                _ = try await session.command(
                    """
                    CREATE TABLE scim_external_ids (
                        id UUID PRIMARY KEY,
                        organization_id UUID NOT NULL,
                        resource_type TEXT NOT NULL,
                        external_id TEXT NOT NULL,
                        internal_id UUID NOT NULL,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ,
                        CONSTRAINT "uq:scim_external_ids.external_id+resource_type+organization_id"
                            UNIQUE (organization_id, resource_type, external_id)
                    )
                    """,
                    operation: "test.scim_external_ids.schema.create"
                )
            }
            try await test(database, ControlPlanePersistence(database: database).scimExternalIDs)
        }
    }
}
