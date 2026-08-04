import Fluent
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Regression tests for issue #747: `POST /api/volumes/:id/snapshot` used to
/// admit an **attached** volume. The filesystem backend's snapshot is a qcow2
/// overlay whose backing file is the volume, and nothing redirects the running
/// QEMU's active layer onto that overlay — the guest keeps writing the same
/// base the overlay reads through, so the "snapshot" never diverges from the
/// live volume. The operation reported success and returned a valid-looking
/// path for a snapshot that captured nothing.
///
/// The endpoint now refuses an attached volume outright rather than returning
/// a silently-wrong point-in-time image.
@Suite("Volume Snapshot Guard Tests", .serialized)
struct VolumeSnapshotGuardTests {

    /// Boots a test app with an admin caller and one volume in `status`,
    /// provisioned onto a (non-existent) agent so the request reaches the
    /// hypervisor round-trip when the status guard lets it through.
    private func withVolume(
        status: VolumeStatus,
        attachedToVM: Bool = false,
        _ test: (Application, Volume, String) async throws -> Void
    ) async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "snapshot-guard-admin",
                email: "snapshot-guard-admin@example.com",
                displayName: "Snapshot Guard Admin",
                isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app.db)
            let org = try await builder.createOrganization(name: "Snapshot Guard Org")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            admin.currentOrganizationId = org.id
            try await admin.save(on: app.db)
            let project = try await builder.createProject(
                name: "Snapshot Guard Project",
                description: "Project for the attached-snapshot guard",
                organization: org)

            let volume = Volume(
                name: "guard-volume",
                description: "volume under the snapshot guard",
                projectID: project.id!,
                size: 10 * 1024 * 1024 * 1024,
                status: status,
                createdByID: admin.id!)
            volume.hypervisorId = "agent-that-is-not-connected"
            volume.storagePath = "/var/lib/strato/volumes/guard/volume.qcow2"
            if attachedToVM {
                let vm = try await builder.createVM(name: "guard-vm", project: project)
                volume.$vm.id = vm.id
                volume.deviceName = "disk1"
            }
            try await volume.save(on: app.db)

            try await test(app, volume, token)
        }
    }

    private func snapshotBody() -> CreateSnapshotRequest {
        CreateSnapshotRequest(name: "guard-snapshot", description: "taken under test")
    }

    @Test("Snapshotting an attached volume is refused with 409")
    func attachedVolumeIsRefused() async throws {
        try await withVolume(status: .attached, attachedToVM: true) { app, volume, token in
            try await app.test(.POST, "/api/volumes/\(volume.id!)/snapshot") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(self.snapshotBody())
            } afterResponse: { res in
                // Before the fix this returned 200 with a snapshot whose
                // content tracked the live volume forever.
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("detach the volume first"))
            }

            // A refused request leaves no half-built snapshot behind, and the
            // volume never enters `.snapshotting`.
            let snapshotCount = try await VolumeSnapshot.query(on: app.db).count()
            #expect(snapshotCount == 0)
            let reloaded = try #require(try await Volume.find(volume.id, on: app.db))
            #expect(reloaded.status == .attached)
        }
    }

    @Test("Cloning an attached volume is refused with 409")
    func attachedVolumeCannotBeCloned() async throws {
        try await withVolume(status: .attached, attachedToVM: true) { app, volume, token in
            // Clone shares the guard's reasoning: `qemu-img convert` of a file
            // a guest is writing produces a torn copy. It used to share
            // `canSnapshot` outright, so this pins it as its own rule.
            try await app.test(.POST, "/api/volumes/\(volume.id!)/clone") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CloneVolumeRequest(name: "guard-clone", description: nil))
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("detach the volume first"))
            }

            let volumeCount = try await Volume.query(on: app.db).count()
            #expect(volumeCount == 1)
        }
    }

    @Test("Snapshotting a detached volume passes the status guard")
    func detachedVolumeIsAdmitted() async throws {
        try await withVolume(status: .available) { app, volume, token in
            try await app.test(.POST, "/api/volumes/\(volume.id!)/snapshot") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(self.snapshotBody())
            } afterResponse: { res in
                // The status guard admits it; the request then fails at the
                // agent round-trip, since no agent is connected in tests.
                #expect(res.status == .badGateway)
                #expect(!res.body.string.contains("detach the volume first"))
            }

            // The snapshot row survives as an `.error` record, and the volume
            // is put back the way it was found.
            let snapshot = try #require(try await VolumeSnapshot.query(on: app.db).first())
            #expect(snapshot.status == .error)
            let reloaded = try #require(try await Volume.find(volume.id, on: app.db))
            #expect(reloaded.status == .available)
        }
    }
}
