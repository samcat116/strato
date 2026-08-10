import Fluent
import SQLKit
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// STR-129: the volume↔VM attachment used to be four independent columns with
/// no constraint, no transaction and no validation tying them together.
///
/// Two failures fell out of that, both reachable through ordinary API use:
/// deleting a VM left its volumes `attached` to nothing — undeletable,
/// unattachable, invisible to every sweep — and two concurrent attaches could
/// claim one device name, after which a detach resolved the disk by that name
/// and could unplug the wrong one.
@Suite("Volume Attachment Tests", .serialized)
struct VolumeAttachmentTests {

    /// A system admin, an org, a project, and a QEMU VM with no agent — which
    /// is what keeps these tests off the agent dispatch: every check under test
    /// answers before the hot-plug request is sent.
    private func withAttachmentApp(
        _ test: (Application, TestDataBuilder, User, Project, VM, String) async throws -> Void
    ) async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "attachment-admin",
                email: "attachment-admin@example.com",
                displayName: "Attachment Admin",
                isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app.db)
            let org = try await builder.createOrganization(name: "Attachment Org")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            admin.currentOrganizationId = org.id
            try await admin.save(on: app.db)

            let project = try await builder.createProject(
                name: "Attachment Project",
                description: "Project for volume attachment tests",
                organization: org)
            let vm = try await builder.createVM(name: "attachment-vm", project: project)

            try await test(app, builder, admin, project, vm, token)
        }
    }

    @discardableResult
    private func makeVolume(
        named name: String,
        attachedTo vm: VM? = nil,
        deviceName: String? = nil,
        bootOrder: Int? = nil,
        on app: Application,
        user: User,
        project: Project
    ) async throws -> Volume {
        let volume = Volume(
            name: name,
            description: "",
            projectID: try project.requireID(), environment: "development",
            size: 10 * 1024 * 1024 * 1024,
            status: vm == nil ? .available : .attached,
            createdByID: try user.requireID())
        if let vm {
            volume.$vm.id = try vm.requireID()
            volume.deviceName = deviceName ?? "disk0"
            volume.bootOrder = bootOrder
        }
        try await volume.save(on: app.db)
        return volume
    }

    private func attach(
        _ volume: Volume, to vm: VM, deviceName: String? = nil, bootOrder: Int? = nil,
        token: String, on app: Application, expecting status: HTTPStatus,
        reason: String? = nil
    ) async throws {
        try await app.test(.POST, "/api/volumes/\(try volume.requireID())/attach") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(
                AttachVolumeRequest(
                    vmId: try vm.requireID(), deviceName: deviceName, bootOrder: bootOrder,
                    readonly: nil))
        } afterResponse: { res in
            #expect(res.status == status)
            if let reason {
                #expect(res.body.string.contains(reason))
            }
        }
    }

    // MARK: - Deleting a VM

    @Test("Deleting a VM detaches its volumes instead of stranding them")
    func deletingAVMDetachesItsVolumes() async throws {
        try await withAttachmentApp { app, _, admin, project, vm, _ in
            let volume = try await makeVolume(
                named: "reaped-vm-volume", attachedTo: vm, deviceName: "disk0", bootOrder: 0,
                on: app, user: admin, project: project)
            volume.attachedAgentId = "agent-a"
            try await volume.save(on: app.db)
            let vmID = try vm.requireID()
            let generationBefore = volume.generation

            // The unplaced delete path: nothing has to confirm a teardown that
            // never reached an agent, so the first clear reaps the row.
            vm.finalizers = []
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.db)
            let outcome = try await ResourceFinalizerService.clear(
                .agentAbsent, from: vm, on: app.db, app: app)

            #expect(outcome == .reaped)
            #expect(try await VM.find(vmID, on: app.db) == nil)

            // Before the fix the FK cleared `vm_id` and left everything else,
            // so the volume named a device on a VM that no longer existed.
            let reloaded = try #require(try await Volume.find(volume.id, on: app.db))
            #expect(reloaded.$vm.id == nil)
            #expect(reloaded.deviceName == nil)
            #expect(reloaded.bootOrder == nil)
            #expect(reloaded.attachedAgentId == nil)
            #expect(reloaded.canDelete)
            #expect(reloaded.canAttach)
            // The bump is what the agent acts on: without it the desired entry
            // is no newer than the one it applied, so the disk would stay
            // plugged into a guest nothing describes.
            #expect(reloaded.generation > generationBefore)
            // `status` is observed, so the control plane does not move it — the
            // agent's next report does.
            #expect(reloaded.status == .attached)
        }
    }

    @Test("A volume detached from a deleted VM is attachable again")
    func aReleasedVolumeCanBeReattached() async throws {
        try await withAttachmentApp { app, builder, admin, project, vm, token in
            let volume = try await makeVolume(
                named: "reusable-volume", attachedTo: vm, on: app, user: admin, project: project)

            vm.finalizers = []
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.db)
            try await ResourceFinalizerService.clear(.agentAbsent, from: vm, on: app.db, app: app)

            // A fresh VM, and the volume goes back to work: the attach is
            // accepted rather than refused as still attached to the VM that no
            // longer exists. Only the acceptance is asserted — this fixture is
            // on no agent, so `.stateSync` dispatch degrades the mutation and
            // `resolveForStuckOperation` reverts the attachment behind us.
            let replacement = try await builder.createVM(name: "replacement-vm", project: project)
            try await attach(volume, to: replacement, token: token, on: app, expecting: .accepted)
        }
    }

    @Test("The database refuses to delete a VM that still has a volume attached")
    func theDatabaseRefusesToOrphanAVolume() async throws {
        try await withAttachmentApp { app, _, admin, project, vm, _ in
            let volume = try await makeVolume(
                named: "restrict-volume", attachedTo: vm, on: app, user: admin, project: project)

            // `ON DELETE SET NULL` is what made the stranding silent: it cleared
            // `vm_id` and left the rest. RESTRICT means a delete path that
            // forgets its volumes fails loudly instead.
            await #expect(throws: (any Error).self) {
                try await vm.delete(on: app.db)
            }

            let reloaded = try #require(try await Volume.find(volume.id, on: app.db))
            #expect(reloaded.$vm.id == vm.id)
            #expect(reloaded.status == .attached)
        }
    }

    // MARK: - Device names

    @Test("An attach naming a device that is already taken on the VM is refused")
    func duplicateDeviceNameIsRefused() async throws {
        try await withAttachmentApp { app, _, admin, project, vm, token in
            try await makeVolume(
                named: "first-volume", attachedTo: vm, deviceName: "disk0",
                on: app, user: admin, project: project)
            let second = try await makeVolume(
                named: "second-volume", on: app, user: admin, project: project)

            try await attach(
                second, to: vm, deviceName: "disk0", token: token, on: app,
                expecting: .conflict, reason: "already in use on this VM")

            // Refused before anything was written.
            let reloaded = try #require(try await Volume.find(second.id, on: app.db))
            #expect(reloaded.status == .available)
            #expect(reloaded.$vm.id == nil)
        }
    }

    @Test("An attach naming a device a hypervisor would refuse is rejected at the boundary")
    func illegalDeviceNameIsRejected() async throws {
        try await withAttachmentApp { app, _, admin, project, vm, token in
            let volume = try await makeVolume(
                named: "illegal-name-volume", on: app, user: admin, project: project)

            for name in ["disk 1", "", "/var/lib/strato/disk", "-disk"] {
                try await attach(
                    volume, to: vm, deviceName: name, token: token, on: app,
                    expecting: .badRequest, reason: "Invalid device name")
            }

            let reloaded = try #require(try await Volume.find(volume.id, on: app.db))
            #expect(reloaded.deviceName == nil)
            #expect(reloaded.$vm.id == nil)
        }
    }

    @Test("Generated device names do not collide with what the VM already has")
    func generatedNamesSkipTakenSlots() async throws {
        try await withAttachmentApp { app, _, admin, project, vm, _ in
            try await makeVolume(
                named: "taken-disk0", attachedTo: vm, deviceName: "disk0",
                on: app, user: admin, project: project)
            let second = try await makeVolume(
                named: "generated-name", on: app, user: admin, project: project)

            // Through the service rather than the endpoint, because the claim
            // itself is what is under test: `disk0` is taken, so the generated
            // name must not be it.
            let generationBefore = second.generation
            let claimed = try await app.db.transaction { tx in
                try await VolumeAttachmentService.claim(
                    second, to: vm, deviceName: nil, bootOrder: nil, readonly: false, on: tx)
            }
            #expect(claimed.rawValue == "disk1")

            let reloaded = try #require(try await Volume.find(second.id, on: app.db))
            #expect(reloaded.deviceName == "disk1")
            #expect(reloaded.$vm.id == vm.id)
            // `claim` is deliberately state-only. The HTTP path wraps it in
            // `ResourceMutation.accept`, which owns the single generation
            // advance after the attachment mutation succeeds.
            #expect(reloaded.generation == generationBefore)
        }
    }

    @Test("An attach against a stale snapshot loses to the one that committed first")
    func aStaleSnapshotCannotMoveAnAttachment() async throws {
        try await withAttachmentApp { app, builder, admin, project, vm, _ in
            let volume = try await makeVolume(
                named: "contended-volume", on: app, user: admin, project: project)
            let other = try await builder.createVM(name: "second-vm", project: project)

            // The instance a request loaded before a competing attach committed.
            // `claim` runs against exactly this: `ResourceMutation.accept` hands
            // the closure the model the controller fetched, refreshed by
            // `lockAndRefresh` — so the guard is only as good as what that
            // refresh adopts.
            let stale = try #require(try await Volume.find(volume.id, on: app.db))

            try await app.db.transaction { tx in
                let winner = try #require(try await Volume.find(volume.id, on: tx))
                try await VolumeAttachmentService.claim(
                    winner, to: vm, deviceName: nil, bootOrder: nil, readonly: false, on: tx)
            }

            // Before `adoptReconciliationState` carried the attachment, the
            // stale `$vm.id == nil` passed `canAttach` and the save moved the
            // volume off the VM that already had it — both callers answered
            // `202`, and the unique index could not see it, since the two
            // rows-in-time name different VMs.
            await #expect(throws: (any Error).self) {
                try await app.db.transaction { tx in
                    #expect(try await stale.lockAndRefresh(on: tx))
                    try await VolumeAttachmentService.claim(
                        stale, to: other, deviceName: nil, bootOrder: nil, readonly: false, on: tx)
                }
            }

            let reloaded = try #require(try await Volume.find(volume.id, on: app.db))
            #expect(reloaded.$vm.id == vm.id)
        }
    }

    @Test("The database refuses two volumes claiming one device name on a VM")
    func theDatabaseRefusesDuplicateDeviceNames() async throws {
        try await withAttachmentApp { app, _, admin, project, vm, _ in
            try await makeVolume(
                named: "index-first", attachedTo: vm, deviceName: "disk0",
                on: app, user: admin, project: project)

            // The backstop under the advisory lock: whatever slips past the
            // application's checks — a racing replica, a future call site —
            // cannot land two disks on one device name.
            await #expect(throws: (any Error).self) {
                try await self.makeVolume(
                    named: "index-second", attachedTo: vm, deviceName: "disk0",
                    on: app, user: admin, project: project)
            }
        }
    }

    @Test("The database refuses an attached volume that names no device")
    func theDatabaseRefusesANamelessAttachment() async throws {
        try await withAttachmentApp { app, _, admin, project, vm, _ in
            let volume = Volume(
                name: "nameless-attachment", description: "",
                projectID: try project.requireID(), environment: "development", size: 1 << 30, status: .attached,
                createdByID: try admin.requireID())
            volume.$vm.id = try vm.requireID()

            await #expect(throws: (any Error).self) {
                try await volume.save(on: app.db)
            }
        }
    }

    // MARK: - Boot order

    @Test("An attach reusing a boot order already on the VM is refused")
    func duplicateBootOrderIsRefused() async throws {
        try await withAttachmentApp { app, _, admin, project, vm, token in
            try await makeVolume(
                named: "boot-first", attachedTo: vm, deviceName: "disk0", bootOrder: 1,
                on: app, user: admin, project: project)
            let second = try await makeVolume(
                named: "boot-second", on: app, user: admin, project: project)

            try await attach(
                second, to: vm, deviceName: "disk1", bootOrder: 1, token: token, on: app,
                expecting: .conflict, reason: "Boot order 1 is already in use")
        }
    }

    @Test("A negative boot order is rejected")
    func negativeBootOrderIsRejected() async throws {
        try await withAttachmentApp { app, _, admin, project, vm, token in
            let volume = try await makeVolume(
                named: "negative-boot-order", on: app, user: admin, project: project)

            try await attach(
                volume, to: vm, bootOrder: -1, token: token, on: app,
                expecting: .badRequest, reason: "must not be negative")
        }
    }

    // MARK: - Sweep backstop

    @Test("The sweep detaches a volume left pointing at nothing")
    func sweepRecoversAStrandedAttachment() async throws {
        try await withAttachmentApp { app, _, admin, project, _, _ in
            // The shape a pre-fix VM delete left behind, which a replica running
            // an older build can still produce mid-rollout.
            let volume = try await makeVolume(
                named: "stranded-volume", on: app, user: admin, project: project)
            volume.status = .attached
            volume.deviceName = "disk0"
            volume.bootOrder = 0
            volume.readonly = true
            volume.attachedAgentId = "agent-a"
            try await volume.save(on: app.db)
            let generationBefore = volume.generation

            await app.agentService.sweepStrandedVolumeAttachments()

            let swept = try #require(try await Volume.find(volume.id, on: app.db))
            #expect(swept.deviceName == nil)
            #expect(swept.bootOrder == nil)
            #expect(swept.readonly == false)
            #expect(swept.attachedAgentId == nil)
            #expect(swept.generation > generationBefore)
            // `status` is the agent's observation, so the sweep does not invent
            // one — it repairs the attachment and lets the next report speak.
            #expect(swept.status == .attached)
        }
    }

    @Test("The sweep leaves a healthy attachment alone")
    func sweepIgnoresAHealthyAttachment() async throws {
        try await withAttachmentApp { app, _, admin, project, vm, _ in
            let volume = try await makeVolume(
                named: "healthy-attachment", attachedTo: vm, deviceName: "disk0", bootOrder: 0,
                on: app, user: admin, project: project)
            let generationBefore = volume.generation

            await app.agentService.sweepStrandedVolumeAttachments()

            let swept = try #require(try await Volume.find(volume.id, on: app.db))
            #expect(swept.deviceName == "disk0")
            #expect(swept.$vm.id == vm.id)
            #expect(swept.generation == generationBefore)
        }
    }
}
