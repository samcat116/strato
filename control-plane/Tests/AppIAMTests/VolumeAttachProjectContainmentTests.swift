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
        _ test: (Application, Volume, VM, String) async throws -> Void
    ) async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "attach-containment-admin",
                email: "attach-containment-admin@example.com",
                displayName: "Attach Containment Admin",
                isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app.db)
            let org = try await builder.createOrganization(name: "Attach Containment Org")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            admin.currentOrganizationId = org.id
            try await admin.save(on: app.db)

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
                projectID: volumeProject.id!,
                size: 10 * 1024 * 1024 * 1024,
                status: .available,
                createdByID: admin.id!)
            volume.hypervisorId = "agent-that-is-not-connected"
            volume.storagePath = "/var/lib/strato/volumes/containment/volume.qcow2"
            try await volume.save(on: app.db)

            let vm = try await builder.createVM(name: "containment-vm", project: vmProject)
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
            #expect(reloaded.$vm.id == nil)
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
                // Pin the *specific* downstream failure, not merely the absence
                // of the containment message: an attach that clears every guard
                // dies at the agent dispatch (`VolumeServiceError.agentNotFound`
                // is not an `AbortError`, so it surfaces as 500). Asserting only
                // that the containment reason is missing would still pass if a
                // refactor moved some earlier-firing check ahead of the guard —
                // any such check answers 400/403/404/409 and fails here.
                #expect(res.status == .internalServerError)
                #expect(!res.body.string.contains("belongs to a different project"))
            }

            // The agent-side failure path restores the volume, so a rejected
            // hot-plug is indistinguishable from never having been requested.
            let reloaded = try #require(try await Volume.find(volume.id, on: app.db))
            #expect(reloaded.status == .available)
            #expect(reloaded.$vm.id == nil)
        }
    }
}
