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
            let token = try await admin.generateAPIKey(on: app)
            let org = try await builder.createOrganization(name: "Snapshot Guard Org")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            try await admin.replacingCurrentOrganization(org.id).save(on: app.db)
            let project = try await builder.createProject(
                name: "Snapshot Guard Project",
                description: "Project for the attached-snapshot guard",
                organization: org)

            var volume = Volume(
                name: "guard-volume",
                description: "volume under the snapshot guard",
                projectID: project.id!, environment: "development",
                size: 10 * 1024 * 1024 * 1024,
                status: status,
                createdByID: admin.id!)
            if attachedToVM {
                let vm = try await builder.createVM(name: "guard-vm", project: project)
                volume = volume.replacing(
                    vmID: .some(vm.id), deviceName: .some("disk1"))
            }
            try await volume.save(on: app.db)
            try await placeVolume(
                volume,
                on: "agent-that-is-not-connected",
                at: "/var/lib/strato/volumes/guard/volume.qcow2",
                using: app.db
            )

            try await test(app, volume, token)
        }
    }

    private func snapshotBody() -> CreateSnapshotRequest {
        CreateSnapshotRequest(name: "guard-snapshot", description: "taken under test", ttlSeconds: nil)
    }

    @Test("Snapshotting a stopped VM's attached volume is refused with 409")
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
            let snapshotCount = try await VolumeSnapshot.all(on: app.db).count
            #expect(snapshotCount == 0)
            let reloaded = try #require(try await Volume.find(volume.id, on: app.db))
            #expect(reloaded.status == .attached)
        }
    }

    @Test("Cloning a running VM's attached volume is refused with 409")
    func runningAttachedVolumeCannotBeCloned() async throws {
        try await withVolume(status: .attached, attachedToVM: true) { app, volume, token in
            var vm = try #require(try await VM.find(volume.vmID, on: app.db))
            vm.status = .running
            vm.desiredStatus = .running
            try await vm.persist(on: app.db)

            // Clone admission allows a stopped attachment because the agent
            // serializes the copy with that VM. A running attachment is still
            // unsafe: `qemu-img convert` would race guest writes.
            try await app.test(.POST, "/api/volumes/\(volume.id!)/clone") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CloneVolumeRequest(name: "guard-clone", description: nil))
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("only while its VM is shut down"))
            }

            let volumeCount = try await Volume.all(on: app.db).count
            #expect(volumeCount == 1)
        }
    }

    /// The status guard admits it and the *capture-admission* guard is what
    /// refuses next: no agent is registered in this suite, so nothing could
    /// converge the artifact (STR-150). Distinguishing the two messages is the
    /// point — a caller told "detach the volume first" when the real problem is
    /// an unreachable agent would do the wrong thing about it.
    @Test("Snapshotting a detached volume passes the status guard")
    func detachedVolumeIsAdmitted() async throws {
        try await withVolume(status: .available) { app, volume, token in
            try await app.test(.POST, "/api/volumes/\(volume.id!)/snapshot") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(self.snapshotBody())
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(!res.body.string.contains("detach the volume first"))
            }

            // Nothing was admitted, so no row was inserted — and the volume,
            // which no longer borrows a `.snapshotting` status to represent a
            // snapshot, is untouched.
            #expect(try await VolumeSnapshot.all(on: app.db).count == 0)
            let reloaded = try #require(try await Volume.find(volume.id, on: app.db))
            #expect(reloaded.status == .available)
        }
    }
}
