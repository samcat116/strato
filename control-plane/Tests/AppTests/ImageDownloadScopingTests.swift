import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Tests for scoping agent image downloads to the images an agent was actually
/// handed (issue #562). The control plane records a coordination grant at every
/// point it emits download URLs — desired-state sync assembly for a VM placed
/// on the agent, and the volume create it asks an agent to service — and the
/// download route serves an agent only what it holds a grant for.
///
/// The route-level half of this lives in `ImageDownloadMTLSTests`, which has
/// the running-server harness the XFCC provenance check needs; these cover the
/// grant-recording side, where a missed path would mean a silently broken image
/// pull in production.
@Suite("Image download scoping", .serialized)
final class ImageDownloadScopingTests {

    private func withScopingApp(
        _ test: (Application, TestDataBuilder, Project, User) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "scoping-user", email: "scoping@example.com")
            let org = try await builder.createOrganization(name: "Scoping Org")
            let project = try await builder.createProject(
                name: "Scoping Project", description: "image download scoping", organization: org)

            try await test(app, builder, project, user)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    /// Registers an online agent that supports QEMU and returns its UUID string.
    private func registerAgent(app: Application, named name: String) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: name,
            hostname: "\(name).test",
            version: "1.0.0",
            capabilities: ["qemu"],
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: 2
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let uuid = try await app.agentService.registerAgent(
            message, agentName: name, organizationScope: orgID.map { .organization($0) })
        return uuid.uuidString
    }

    private func hasGrant(app: Application, agentId: String, image: Image) async -> Bool {
        await app.coordination.hasImageDownloadGrant(agentId: agentId, imageId: image.id!) ?? false
    }

    @Test("Sync assembly grants the agent it places a VM on, and only that agent")
    func syncAssemblyGrantsPlacedImage() async throws {
        try await withScopingApp { app, builder, project, user in
            let image = try await builder.createImage(
                project: project, uploadedBy: user, storagePath: "scoping/disk.qcow2")
            let placedAgent = try await self.registerAgent(app: app, named: "placed-agent")
            let otherAgent = try await self.registerAgent(app: app, named: "other-agent")

            let vm = try await builder.createVM(name: "scoped-vm", project: project)
            vm.hypervisorId = placedAgent
            vm.$sourceImage.id = image.id
            try await vm.save(on: app.db)

            let message = try await app.agentService.assembleDesiredState(agentId: placedAgent)
            #expect(message.vms.first?.imageInfo?.imageId == image.id)

            #expect(await self.hasGrant(app: app, agentId: placedAgent, image: image))

            // The agent the VM is not placed on assembles an empty sync, and
            // gets nothing — this is the isolation the issue asks for.
            let empty = try await app.agentService.assembleDesiredState(agentId: otherAgent)
            #expect(empty.vms.isEmpty)
            #expect(await self.hasGrant(app: app, agentId: otherAgent, image: image) == false)
        }
    }

    @Test("Sync assembly grants nothing for a VM whose image is not ready")
    func notReadyImageIsNotGranted() async throws {
        try await withScopingApp { app, builder, project, user in
            // A pending image emits no download URLs, so it must leave no
            // grant behind either.
            let image = try await builder.createImage(
                project: project, status: .pending, uploadedBy: user)
            let agentId = try await self.registerAgent(app: app, named: "pending-image-agent")

            let vm = try await builder.createVM(name: "pending-image-vm", project: project)
            vm.hypervisorId = agentId
            vm.$sourceImage.id = image.id
            try await vm.save(on: app.db)

            let message = try await app.agentService.assembleDesiredState(agentId: agentId)
            #expect(message.vms.first?.imageInfo == nil)
            #expect(await self.hasGrant(app: app, agentId: agentId, image: image) == false)
        }
    }

    @Test("A volume create from an image grants the agent it is dispatched to")
    func volumeCreateGrantsSelectedAgent() async throws {
        try await withScopingApp { app, builder, project, user in
            // The volume path is the one image fetch with no VM placement to
            // authorize it: the volume has no replica until the agent answers.
            let image = try await builder.createImage(
                project: project, uploadedBy: user, storagePath: "scoping/volume-source.qcow2")
            let agentId = try await self.registerAgent(app: app, named: "volume-agent")

            let volume = Volume(
                name: "scoped-volume",
                description: "volume from image",
                projectID: project.id!,
                size: 10 * 1024 * 1024 * 1024,
                format: .qcow2,
                volumeType: .boot,
                createdByID: user.id!
            )
            try await volume.save(on: app.db)

            // No socket is attached, so the request itself fails — but the
            // grant is written before the message goes out, which is the
            // ordering that keeps a fast agent from racing its own URL.
            _ = try? await app.volumeService.requestVolumeCreation(volume: volume, sourceImage: image)

            #expect(await self.hasGrant(app: app, agentId: agentId, image: image))
        }
    }
}
