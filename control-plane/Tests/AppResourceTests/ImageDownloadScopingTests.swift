import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
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
    /// `protocolVersion` defaults to the current wire version because the
    /// volume cases below need an agent that speaks volume sync (STR-148); the
    /// VM cases are indifferent to it.
    private func registerAgent(
        app: Application, named name: String, protocolVersion: Int = WireProtocol.currentVersion
    ) async throws -> String {
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
            protocolVersion: protocolVersion
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

            let message = try await app.desiredStateAssembler.assemble(agentId: placedAgent)
            #expect(message.vms.first?.imageInfo?.imageId == image.id)

            #expect(await self.hasGrant(app: app, agentId: placedAgent, image: image))

            // The agent the VM is not placed on assembles an empty sync, and
            // gets nothing — this is the isolation the issue asks for.
            let empty = try await app.desiredStateAssembler.assemble(agentId: otherAgent)
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

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            #expect(message.vms.first?.imageInfo == nil)
            #expect(await self.hasGrant(app: app, agentId: agentId, image: image) == false)
        }
    }

    /// The volume-from-image grant moved from RPC dispatch to sync assembly
    /// with STR-148, because there is no dispatch left: a volume's image is
    /// fetched by the agent converging its desired entry, and assembly is the
    /// only place that knows which agent that is. Same invariant as the VM
    /// case above — emitting the URLs is what authorizes the fetch.
    @Test("Assembling a volume's desired state grants its agent the source image")
    func volumeAssemblyGrantsPlacedAgent() async throws {
        try await withScopingApp { app, builder, project, user in
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
                createdByID: user.id!,
                sourceImageID: image.id
            )
            volume.hypervisorId = agentId
            try await volume.save(on: app.db)

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            #expect(message.volumes?.first?.source?.kind == DesiredVolumeSource.image)
            #expect(await self.hasGrant(app: app, agentId: agentId, image: image))
        }
    }

    /// The other half of the scoping rule: a volume placed elsewhere must not
    /// appear in — or grant anything through — this agent's sync.
    @Test("A volume placed on another agent grants nothing here")
    func volumeOnOtherAgentIsNotGranted() async throws {
        try await withScopingApp { app, builder, project, user in
            let image = try await builder.createImage(
                project: project, uploadedBy: user, storagePath: "scoping/volume-elsewhere.qcow2")
            let owner = try await self.registerAgent(app: app, named: "volume-owner")
            let other = try await self.registerAgent(app: app, named: "volume-bystander")

            let volume = Volume(
                name: "elsewhere-volume",
                description: "volume from image",
                projectID: project.id!,
                size: 10 * 1024 * 1024 * 1024,
                format: .qcow2,
                volumeType: .boot,
                createdByID: user.id!,
                sourceImageID: image.id
            )
            volume.hypervisorId = owner
            try await volume.save(on: app.db)

            let message = try await app.desiredStateAssembler.assemble(agentId: other)
            #expect(message.volumes?.isEmpty == true)
            #expect(await self.hasGrant(app: app, agentId: other, image: image) == false)
        }
    }

    /// The property the long-poll design leans on (STR-146). A conditional
    /// poll assembles at least once even when it ends in `304`, so grants get
    /// recorded for payloads that are never delivered — routinely, not just in
    /// a race. That is safe only because a grant is *additive* and scoped to
    /// the placement the assembly just read: re-recording one for an agent
    /// that currently holds the placement is exactly right (it may be mid-pull),
    /// and re-recording cannot widen access beyond what that placement already
    /// authorizes.
    ///
    /// The rejected "cache assembled payloads" alternative is different in
    /// kind: it would grant against a *stale* placement. If grants ever become
    /// scoped-and-narrowing rather than additive, this test is where that
    /// shows up.
    @Test("Re-assembling is idempotent: a repeated grant neither widens nor revokes")
    func repeatedAssemblyGrantsIdempotently() async throws {
        try await withScopingApp { app, builder, project, user in
            let image = try await builder.createImage(
                project: project, uploadedBy: user, storagePath: "scoping/repeat.qcow2")
            let other = try await builder.createImage(
                name: "Repeat Other Image", project: project, uploadedBy: user,
                storagePath: "scoping/repeat-other.qcow2")
            let agentId = try await self.registerAgent(app: app, named: "repeat-agent")

            let vm = try await builder.createVM(name: "repeat-vm", project: project)
            vm.hypervisorId = agentId
            vm.$sourceImage.id = image.id
            try await vm.save(on: app.db)

            for _ in 0..<3 {
                _ = try await app.desiredStateAssembler.assemble(agentId: agentId)
            }

            #expect(await self.hasGrant(app: app, agentId: agentId, image: image))
            // Still exactly the placement's image — repetition does not
            // accumulate access to anything else in the project.
            #expect(await self.hasGrant(app: app, agentId: agentId, image: other) == false)
        }
    }

    /// An assembly whose payload is discarded (the `304` path) must leave the
    /// grant behind anyway, because the agent's *previous* payload gave it URLs
    /// it may still be fetching. A grant that only survived delivered syncs
    /// would expire under a converged agent mid-pull.
    @Test("A grant survives an assembly whose payload is never delivered")
    func grantSurvivesUndeliveredAssembly() async throws {
        try await withScopingApp { app, builder, project, user in
            let image = try await builder.createImage(
                project: project, uploadedBy: user, storagePath: "scoping/undelivered.qcow2")
            let agentId = try await self.registerAgent(app: app, named: "undelivered-agent")

            let vm = try await builder.createVM(name: "undelivered-vm", project: project)
            vm.hypervisorId = agentId
            vm.$sourceImage.id = image.id
            try await vm.save(on: app.db)

            // Assemble and throw the payload away, exactly as the poll handler
            // does when the digest matches the client's validator.
            _ = try await app.desiredStateAssembler.assemble(agentId: agentId)

            #expect(await self.hasGrant(app: app, agentId: agentId, image: image))
        }
    }
}
