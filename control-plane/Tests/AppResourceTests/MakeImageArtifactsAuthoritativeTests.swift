import Fluent
import Foundation
import StratoShared
import Testing

import AppTestSupport
@testable import App

@Suite("MakeImageArtifactsAuthoritative migration", .serialized)
struct MakeImageArtifactsAuthoritativeTests {
    private func seedLegacyReadyImage(
        on database: Database, projectID: UUID, userID: UUID,
        filename: String = "disk.qcow2", checksum: String? = String(repeating: "a", count: 64),
        storagePath: String? = "images/disk.qcow2"
    ) async throws -> UUID {
        let image = Image(
            name: "legacy", description: "", projectID: projectID,
            architecture: .x86_64, status: .ready, uploadedByID: userID)
        try await image.save(on: database)
        let imageID = try image.requireID()

        let legacy = try #require(
            try await AuthoritativeImageLegacyRow.find(imageID, on: database))
        legacy.filename = filename
        legacy.size = 512
        legacy.format = ImageFormat.qcow2.rawValue
        legacy.architecture = CPUArchitecture.x86_64.rawValue
        legacy.checksum = checksum
        legacy.storagePath = storagePath
        legacy.status = ImageStatus.ready.rawValue
        try await legacy.save(on: database)
        return imageID
    }

    @Test("Cutover backfills complete legacy bytes before dropping duplicate columns")
    func backfillsBeforeCutover() async throws {
        try await withTestApp { app in
            let migration = MakeImageArtifactsAuthoritative()
            try await migration.revert(on: app.db)

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser()
            let org = try await builder.createOrganization()
            let project = try await builder.createProject(
                name: "p", description: "d", organization: org)
            let imageID = try await seedLegacyReadyImage(
                on: app.db, projectID: try project.requireID(), userID: try user.requireID())

            try await migration.prepare(on: app.db)

            let artifact = try #require(
                try await ImageArtifact.query(on: app.db)
                    .filter(\.$image.$id == imageID)
                    .filter(\.$kind == .diskImage)
                    .first())
            #expect(artifact.isUsable)
            #expect(artifact.filename == "disk.qcow2")
            #expect(artifact.storagePath == "images/disk.qcow2")
        }
    }

    @Test("Cutover refuses a ready image whose legacy and typed records are incomplete")
    func refusesIncompleteReadyImages() async throws {
        try await withTestApp { app in
            let migration = MakeImageArtifactsAuthoritative()
            try await migration.revert(on: app.db)

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser()
            let org = try await builder.createOrganization()
            let project = try await builder.createProject(
                name: "p", description: "d", organization: org)
            _ = try await seedLegacyReadyImage(
                on: app.db, projectID: try project.requireID(), userID: try user.requireID(),
                filename: "", checksum: nil, storagePath: nil)

            await #expect(throws: ImageArtifactCutoverError.self) {
                try await migration.prepare(on: app.db)
            }
        }
    }
}
