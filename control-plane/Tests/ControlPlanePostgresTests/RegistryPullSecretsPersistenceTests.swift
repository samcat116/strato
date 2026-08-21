import Foundation
import Testing

@testable import ControlPlanePostgres

@Suite("Native registry pull-secret persistence", .serialized)
struct RegistryPullSecretsPersistenceTests {
    @Test("credentials round-trip through create, lookup, update, and delete")
    func lifecycle() async throws {
        try await withRegistryPullSecretDatabase { secrets in
            let projectID = UUID()
            let created = try await secrets.create(
                RegistryPullSecretWrite(
                    projectID: projectID,
                    registry: "ghcr.io",
                    username: "robot",
                    encryptedSecret: "enc:v1:initial"
                )
            )
            #expect(created.projectID == projectID)
            #expect(created.registry == "ghcr.io")
            #expect(created.createdAt != nil)
            #expect(created.updatedAt != nil)
            #expect(try await secrets.secrets(projectID: projectID) == [created])
            #expect(try await secrets.secret(id: created.id, projectID: projectID) == created)
            #expect(try await secrets.secret(id: created.id, projectID: UUID()) == nil)

            let updated = try #require(
                try await secrets.update(
                    id: created.id,
                    projectID: projectID,
                    username: "robot-2",
                    encryptedSecret: "enc:v1:rotated"
                )
            )
            #expect(updated.username == "robot-2")
            #expect(updated.encryptedSecret == "enc:v1:rotated")

            #expect(try await secrets.delete(id: created.id, projectID: UUID()) == nil)
            #expect(try await secrets.delete(id: created.id, projectID: projectID)?.id == created.id)
            #expect(try await secrets.all().isEmpty)
        }
    }

    @Test("duplicate registries are typed and legacy encryption uses compare-and-swap")
    func uniquenessAndEncryptionConvergence() async throws {
        try await withRegistryPullSecretDatabase { secrets in
            let projectID = UUID()
            let created = try await secrets.create(
                RegistryPullSecretWrite(
                    projectID: projectID,
                    registry: "registry.example.com",
                    username: "robot",
                    encryptedSecret: "plaintext"
                )
            )

            await #expect(
                throws: RegistryPullSecretPersistenceError.duplicateRegistry(
                    projectID: projectID,
                    registry: "registry.example.com"
                )
            ) {
                try await secrets.create(
                    RegistryPullSecretWrite(
                        projectID: projectID,
                        registry: "registry.example.com",
                        username: "other",
                        encryptedSecret: "other"
                    )
                )
            }

            #expect(
                !(try await secrets.replaceEncryptedSecret(
                    id: created.id,
                    expectedCurrentValue: "stale",
                    replacement: "enc:v1:new"
                ))
            )
            #expect(
                try await secrets.replaceEncryptedSecret(
                    id: created.id,
                    expectedCurrentValue: "plaintext",
                    replacement: "enc:v1:new"
                )
            )
            #expect(
                try await secrets.secret(id: created.id, projectID: projectID)?.encryptedSecret
                    == "enc:v1:new"
            )
        }
    }

    private func withRegistryPullSecretDatabase(
        _ test: (RegistryPullSecretsPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            _ = try await database.withSession(operation: "test.registry_pull_secrets.schema") {
                session in
                try await session.command(
                    """
                    CREATE TABLE registry_pull_secrets (
                        id UUID PRIMARY KEY,
                        project_id UUID NOT NULL,
                        registry TEXT NOT NULL,
                        username TEXT NOT NULL,
                        secret TEXT NOT NULL,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ,
                        CONSTRAINT "uq:registry_pull_secrets.project_id+registry_pull_secrets.regis"
                            UNIQUE (project_id, registry)
                    )
                    """,
                    operation: "test.registry_pull_secrets.schema.create"
                )
            }
            try await test(ControlPlanePersistence(database: database).registryPullSecrets)
        }
    }
}
