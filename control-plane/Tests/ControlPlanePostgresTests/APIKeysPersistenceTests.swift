import Foundation
import Testing

@testable import ControlPlanePostgres

@Suite("Native API-key persistence", .serialized)
struct APIKeysPersistenceTests {
    private let unrestricted = StoredCredentialRestriction(
        actions: ["*"],
        nodeType: nil,
        nodeID: nil
    )

    @Test("issue, manage, and delete an owned key")
    func lifecycle() async throws {
        try await withAPIKeyDatabase { _, apiKeys in
            let userID = UUID()
            let issued = try await apiKeys.issue(
                write(userID: userID, suffix: "lifecycle"),
                maximumKeysPerUser: 10
            )
            #expect(issued.userID == userID)
            #expect(issued.name == "key-lifecycle")
            #expect(issued.createdAt != nil)
            #expect(issued.updatedAt == nil)
            #expect(try await apiKeys.keys(userID: userID).map(\.id) == [issued.id])

            let projectID = UUID()
            let changed = try #require(
                try await apiKeys.updateOwnedKey(
                    id: issued.id,
                    userID: userID,
                    changes: APIKeyChanges(
                        name: "renamed",
                        restriction: StoredCredentialRestriction(
                            actions: ["read"],
                            nodeType: "project",
                            nodeID: projectID
                        ),
                        isActive: false
                    )
                )
            )
            #expect(changed.name == "renamed")
            #expect(changed.restriction.actions == ["read"])
            #expect(changed.restriction.nodeType == "project")
            #expect(changed.restriction.nodeID == projectID)
            #expect(!changed.isActive)
            #expect(changed.updatedAt != nil)
            #expect(try await apiKeys.activeKey(keyHash: "hash-lifecycle") == nil)

            #expect(try await apiKeys.deleteOwnedKey(id: issued.id, userID: UUID()) == false)
            #expect(try await apiKeys.deleteOwnedKey(id: issued.id, userID: userID))
            #expect(try await apiKeys.ownedKey(id: issued.id, userID: userID) == nil)
        }
    }

    @Test("the per-user key limit holds under concurrent issuance")
    func concurrentLimit() async throws {
        try await withAPIKeyDatabase(maximumConnections: 2) { _, apiKeys in
            let userID = UUID()
            let outcomes = try await withThrowingTaskGroup(of: Bool.self) { group in
                for suffix in ["first", "second"] {
                    group.addTask {
                        do {
                            _ = try await apiKeys.issue(
                                write(userID: userID, suffix: suffix),
                                maximumKeysPerUser: 1
                            )
                            return true
                        } catch APIKeyPersistenceError.limitReached(maximum: 1) {
                            return false
                        }
                    }
                }

                var values: [Bool] = []
                for try await value in group { values.append(value) }
                return values
            }

            #expect(outcomes.filter { $0 }.count == 1)
            #expect(outcomes.filter { !$0 }.count == 1)
            #expect(try await apiKeys.keys(userID: userID).count == 1)
        }
    }

    @Test("last-used writes debounce and mass deactivation is targeted")
    func usageAndDeactivation() async throws {
        try await withAPIKeyDatabase { _, apiKeys in
            let userID = UUID()
            let otherUserID = UUID()
            let first = try await apiKeys.issue(
                write(userID: userID, suffix: "first"),
                maximumKeysPerUser: 10
            )
            _ = try await apiKeys.issue(
                write(userID: userID, suffix: "second"),
                maximumKeysPerUser: 10
            )
            let other = try await apiKeys.issue(
                write(userID: otherUserID, suffix: "other"),
                maximumKeysPerUser: 10
            )
            let usedAt = Date()

            #expect(
                try await apiKeys.recordUsage(
                    id: first.id,
                    usedAt: usedAt,
                    sourceIP: "198.51.100.1",
                    staleBefore: usedAt.addingTimeInterval(-900)
                )
            )
            #expect(
                !(try await apiKeys.recordUsage(
                    id: first.id,
                    usedAt: usedAt.addingTimeInterval(1),
                    sourceIP: "198.51.100.2",
                    staleBefore: usedAt.addingTimeInterval(-899)
                ))
            )

            let reloaded = try #require(
                try await apiKeys.ownedKey(id: first.id, userID: userID)
            )
            #expect(reloaded.lastUsedIP == "198.51.100.1")
            #expect(try await apiKeys.deactivateAll(userID: userID) == 2)
            #expect(try await apiKeys.deactivateAll(userID: userID) == 0)
            #expect(try await apiKeys.activeKey(keyHash: "hash-other")?.id == other.id)
        }
    }

    private func write(userID: UUID, suffix: String) -> APIKeyWrite {
        APIKeyWrite(
            userID: userID,
            name: "key-\(suffix)",
            keyHash: "hash-\(suffix)",
            keyPrefix: "sk_\(suffix)...",
            restriction: unrestricted
        )
    }

    private func withAPIKeyDatabase(
        maximumConnections: Int = 1,
        _ test: (PostgresDatabase, APIKeysPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase(
            maximumConnections: maximumConnections
        ) { database in
            try await database.withSession(operation: "test.api_keys.schema") { session in
                _ = try await session.command(
                    """
                    CREATE TABLE api_keys (
                        id UUID PRIMARY KEY,
                        user_id UUID NOT NULL,
                        name TEXT NOT NULL,
                        key_hash TEXT NOT NULL UNIQUE,
                        key_prefix TEXT NOT NULL,
                        restriction_actions TEXT[] NOT NULL,
                        restriction_node_type TEXT,
                        restriction_node_id UUID,
                        is_active BOOLEAN NOT NULL,
                        expires_at TIMESTAMPTZ,
                        last_used_at TIMESTAMPTZ,
                        last_used_ip TEXT,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.api_keys.schema.create"
                )
            }
            try await test(
                database,
                ControlPlanePersistence(database: database).apiKeys
            )
        }
    }
}
