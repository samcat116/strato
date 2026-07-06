import Testing
import Vapor
import Fluent
import StratoShared
@testable import App

@Suite("BackfillImageArtifacts migration", .serialized)
struct BackfillImageArtifactsTests {

    @Test("Backfill creates one disk-image artifact per ready image, skips others")
    func backfillsReadyImages() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser()
            let org = try await builder.createOrganization()
            let project = try await builder.createProject(
                name: "p", description: "d", organization: org)

            // A ready image with a stored file — should be backfilled.
            let ready = try await builder.createImage(
                name: "ready", project: project, uploadedBy: user,
                storagePath: "\(project.id!)/ready/disk.qcow2")

            // A pending image with no stored file — should be skipped.
            let pending = try await builder.createImage(
                name: "pending", project: project, status: .pending,
                uploadedBy: user, checksum: nil)

            // The migration's initial run happened on an empty DB; run its data
            // step now that images exist.
            try await BackfillImageArtifacts().prepare(on: app.db)

            let readyArtifacts = try await ImageArtifact.query(on: app.db)
                .filter(\.$image.$id == ready.id!)
                .all()
            #expect(readyArtifacts.count == 1)
            #expect(readyArtifacts.first?.kind == .diskImage)
            #expect(readyArtifacts.first?.storagePath == "\(project.id!)/ready/disk.qcow2")
            #expect(readyArtifacts.first?.architecture == .x86_64)

            let pendingArtifacts = try await ImageArtifact.query(on: app.db)
                .filter(\.$image.$id == pending.id!)
                .count()
            #expect(pendingArtifacts == 0)
        }
    }
}
