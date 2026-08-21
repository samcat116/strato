import Foundation
import Testing

@testable import ControlPlanePostgres

@Suite("Native SCIM-token persistence", .serialized)
struct SCIMTokensPersistenceTests {
    @Test("issue, scope, update, and delete a provisioning token")
    func lifecycle() async throws {
        try await withSCIMTokenDatabase { _, scimTokens in
            let organizationID = UUID()
            let creatorID = UUID()
            let issued = try await scimTokens.issue(
                write(
                    organizationID: organizationID,
                    creatorID: creatorID,
                    suffix: "lifecycle"
                )
            )

            #expect(issued.organizationID == organizationID)
            #expect(issued.createdByID == creatorID)
            #expect(issued.createdAt != nil)
            #expect(issued.updatedAt == nil)
            #expect(try await scimTokens.tokens(organizationID: organizationID).map(\.id) == [issued.id])
            #expect(try await scimTokens.tokens(organizationID: UUID()).isEmpty)
            #expect(try await scimTokens.ownedToken(id: issued.id, organizationID: UUID()) == nil)

            let changed = try #require(
                try await scimTokens.updateOwnedToken(
                    id: issued.id,
                    organizationID: organizationID,
                    changes: SCIMTokenChanges(name: "renamed", isActive: false)
                )
            )
            #expect(changed.name == "renamed")
            #expect(!changed.isActive)
            #expect(changed.updatedAt != nil)
            #expect(try await scimTokens.token(tokenHash: "hash-lifecycle")?.id == issued.id)

            #expect(
                try await scimTokens.deleteOwnedToken(
                    id: issued.id,
                    organizationID: UUID()
                ) == false
            )
            #expect(
                try await scimTokens.deleteOwnedToken(
                    id: issued.id,
                    organizationID: organizationID
                )
            )
            #expect(try await scimTokens.token(tokenHash: "hash-lifecycle") == nil)
        }
    }

    @Test("validity and last-used debounce preserve credential semantics")
    func validityAndUsage() async throws {
        try await withSCIMTokenDatabase { _, scimTokens in
            let organizationID = UUID()
            let creatorID = UUID()
            let now = Date()
            let active = try await scimTokens.issue(
                write(
                    organizationID: organizationID,
                    creatorID: creatorID,
                    suffix: "active"
                )
            )
            let expired = try await scimTokens.issue(
                write(
                    organizationID: organizationID,
                    creatorID: creatorID,
                    suffix: "expired",
                    expiresAt: now.addingTimeInterval(-1)
                )
            )

            #expect(active.isValid(at: now))
            #expect(!expired.isValid(at: now))
            #expect(try await scimTokens.token(tokenHash: "hash-expired")?.id == expired.id)

            #expect(
                try await scimTokens.recordUsage(
                    id: active.id,
                    usedAt: now,
                    sourceIP: "198.51.100.1",
                    staleBefore: now.addingTimeInterval(-900)
                )
            )
            #expect(
                !(try await scimTokens.recordUsage(
                    id: active.id,
                    usedAt: now.addingTimeInterval(1),
                    sourceIP: "198.51.100.2",
                    staleBefore: now.addingTimeInterval(-899)
                ))
            )

            let reloaded = try #require(
                try await scimTokens.ownedToken(
                    id: active.id,
                    organizationID: organizationID
                )
            )
            #expect(reloaded.lastUsedIP == "198.51.100.1")
        }
    }

    private func write(
        organizationID: UUID,
        creatorID: UUID,
        suffix: String,
        expiresAt: Date? = nil
    ) -> SCIMTokenWrite {
        SCIMTokenWrite(
            organizationID: organizationID,
            name: "token-\(suffix)",
            tokenHash: "hash-\(suffix)",
            tokenPrefix: "scim_\(suffix)",
            expiresAt: expiresAt,
            createdByID: creatorID
        )
    }

    private func withSCIMTokenDatabase(
        _ test: (PostgresDatabase, SCIMTokensPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            try await database.withSession(operation: "test.scim_tokens.schema") { session in
                _ = try await session.command(
                    """
                    CREATE TABLE scim_tokens (
                        id UUID PRIMARY KEY,
                        organization_id UUID NOT NULL,
                        name TEXT NOT NULL,
                        token_hash TEXT NOT NULL UNIQUE,
                        token_prefix TEXT NOT NULL,
                        is_active BOOLEAN NOT NULL,
                        expires_at TIMESTAMPTZ,
                        last_used_at TIMESTAMPTZ,
                        last_used_ip TEXT,
                        created_by_id UUID NOT NULL,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.scim_tokens.schema.create"
                )
            }
            try await test(
                database,
                ControlPlanePersistence(database: database).scimTokens
            )
        }
    }
}
