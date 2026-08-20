import Fluent
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Regression tests for issue #766: `POST /api/volumes/:id/attach` authorized
/// the volume (`attach`) and the VM (`update`) independently and never compared
/// their projects. A caller holding rights in two projects — a platform
/// engineer, an org admin, a group granted across a folder — could attach one
/// project's volume to another project's VM, moving the data across the project
/// boundary with no record of the crossing, leaving quota attributed to the
/// volume's project while the workload consuming it lived elsewhere.
///
/// VM create already enforces this containment for networks and security
/// groups; attach was the outlier.
@Suite("Volume Attach Project Containment Tests", .serialized)
struct VolumeAttachProjectContainmentTests {

    /// Boots a test app with a system-admin caller holding real permissions on
    /// both objects — a caller lacking permission would fail at the authz
    /// checks and never reach the containment guard. The volume and the VM are
    /// parked on the same agent so a same-project attach clears the
    /// reachability guard too.
    private func withVolumeAndVM(
        sameProject: Bool,
        volumeEnvironment: String = "development",
        vmEnvironment: String = "development",
        _ test: (Application, Volume, VM, String) async throws -> Void
    ) async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "attach-containment-admin",
                email: "attach-containment-admin@example.com",
                displayName: "Attach Containment Admin",
                isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app)
            let org = try await builder.createOrganization(name: "Attach Containment Org")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            try await admin.replacingCurrentOrganization(org.id).save(on: app.db)

            let volumeProject = try await builder.createProject(
                name: "Volume Project",
                description: "Project owning the volume",
                organization: org)
            let vmProject =
                sameProject
                ? volumeProject
                : try await builder.createProject(
                    name: "VM Project",
                    description: "A second project the caller also has rights in",
                    organization: org)

            let volume = Volume(
                name: "containment-volume",
                description: "volume under the project-containment guard",
                projectID: volumeProject.id!, environment: volumeEnvironment,
                size: 10 * 1024 * 1024 * 1024,
                status: .available,
                createdByID: admin.id!)
            try await volume.save(on: app.db)
            try await placeVolume(
                volume,
                on: "agent-that-is-not-connected",
                at: "/var/lib/strato/volumes/containment/volume.qcow2",
                using: app.db
            )

            var vm = try await builder.createVM(
                name: "containment-vm", project: vmProject, environment: vmEnvironment)
            vm.hypervisorId = "agent-that-is-not-connected"
            try await vm.save(on: app.db)

            try await test(app, volume, vm, token)
        }
    }

    @Test("Attaching a volume to a VM in another project is refused with 400")
    func crossProjectAttachIsRefused() async throws {
        try await withVolumeAndVM(sameProject: false) { app, volume, vm, token in
            try await app.test(.POST, "/api/volumes/\(volume.id!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AttachVolumeRequest(vmId: vm.id!, deviceName: nil, bootOrder: nil, readonly: nil))
            } afterResponse: { res in
                // Before the fix this sailed through both permission checks and
                // bound the volume to the other project's VM.
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("belongs to a different project than the VM"))
            }

            // The refused request leaves the volume untouched: still available,
            // still unbound.
            let reloaded = try #require(try await Volume.find(volume.id, on: app.db))
            #expect(reloaded.status == .available)
            #expect(reloaded.vmID == nil)
            #expect(reloaded.deviceName == nil)
        }
    }

    @Test("Attaching a volume to a VM in its own project passes the containment guard")
    func sameProjectAttachIsAdmitted() async throws {
        try await withVolumeAndVM(sameProject: true) { app, volume, vm, token in
            try await app.test(.POST, "/api/volumes/\(volume.id!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AttachVolumeRequest(vmId: vm.id!, deviceName: nil, bootOrder: nil, readonly: nil))
            } afterResponse: { res in
                // Pin the *specific* success, not merely the absence of the
                // containment message: an attach that clears every guard is
                // accepted (STR-148 — there is no in-band agent dispatch left to
                // fail, so this used to be a 500 from `agentNotFound`).
                // Asserting only that the containment reason is missing would
                // still pass if a refactor moved some earlier-firing check ahead
                // of the guard — any such check answers 400/403/404/409 and
                // fails here.
                #expect(res.status == .accepted)
                #expect(!res.body.string.contains("belongs to a different project"))
            }

            // The volume in this fixture is on no agent, so `.stateSync`
            // dispatch degrades it immediately and `resolveForStuckOperation`
            // reverts the attachment — an unachieved intent left in place would
            // replay on every later sync. A rejected attach is therefore still
            // indistinguishable from never having been requested, just by a
            // different mechanism than the old in-band revert.
            var reloaded = try #require(try await Volume.find(volume.id, on: app.db))
            for _ in 0..<100 where reloaded.conditions.degraded == nil {
                try await Task.sleep(for: .milliseconds(50))
                reloaded = try #require(try await Volume.find(volume.id, on: app.db))
            }
            #expect(reloaded.conditions.degraded != nil)
            #expect(reloaded.vmID == nil)
        }
    }

    @Test("Attaching across environments in one project is refused with 400")
    func crossEnvironmentAttachIsRefused() async throws {
        try await withVolumeAndVM(
            sameProject: true,
            volumeEnvironment: "development",
            vmEnvironment: "production"
        ) { app, volume, vm, token in
            try await app.test(.POST, "/api/volumes/\(volume.id!)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AttachVolumeRequest(
                        vmId: vm.id!, deviceName: nil, bootOrder: nil, readonly: nil))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("same environment"))
            }

            let reloaded = try #require(try await Volume.find(volume.id, on: app.db))
            #expect(reloaded.vmID == nil)
            #expect(reloaded.deviceName == nil)
        }
    }
}
