import Testing
import Vapor
import Fluent
import VaporTesting
import StratoShared
import AppTestSupport
@testable import App

/// The size a volume actually has, next to the size it was asked for (STR-199).
///
/// `size` is desired state: a resize answers `202` and converges, so it moves
/// when the mutation is accepted. Until this column existed it was also the
/// *only* size the API could report, which meant a grow the owning agent had
/// refused — the volume's guest was still running — answered with the size it
/// had failed to reach. That reads exactly like a grow that worked.
///
/// What is pinned here is the pair staying distinguishable, and the one
/// misreading a field with no wire capability gate makes possible: an agent
/// that reports *no* size must not have its silence recorded as "this volume
/// has no size".
@Suite("Volume Observed Size Tests", .serialized)
final class VolumeObservedSizeTests {

    private func withVolumeApp(
        _ test: (Application, User, Project) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "obssizeuser",
                email: "obssize@example.com",
                displayName: "Observed Size User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Observed Size Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Observed Size Project",
                description: "Project for volume observed-size tests",
                organization: org
            )

            try await test(app, user, project)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func registerAgent(app: Application, named name: String) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: name,
            hostname: "\(name).test",
            version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: WireProtocol.currentVersion
        )
        guard let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id else {
            throw Abort(.internalServerError, reason: "Volume test organization is missing")
        }
        let site = Site(
            name: "\(name)-site",
            organizationScope: .organization(orgID))
        try await site.save(on: app.db)
        let uuid = try await app.agentService.registerAgent(
            message,
            agentName: name,
            siteID: try site.requireID(),
            organizationScope: .organization(orgID))
        return uuid.uuidString
    }

    /// A volume whose desired size is `size`, resting at `observedGeneration`.
    private func makeVolume(
        app: Application,
        user: User,
        project: Project,
        agentId: String,
        size: Int64,
        observedSizeBytes: Int64? = nil,
        generation: Int64 = 1,
        observedGeneration: Int64 = 1
    ) async throws -> Volume {
        let pool = try await StoragePool.defaultPool(on: app.db)
        let volume = Volume(
            name: "observed-size-target",
            description: "",
            projectID: project.id!, environment: "development",
            size: size,
            format: .qcow2,
            volumeType: .data,
            status: .available,
            createdByID: user.id!,
            poolID: pool.id
        )
        volume.generation = generation
        volume.observedGeneration = observedGeneration
        volume.observedSizeBytes = observedSizeBytes
        try await volume.save(on: app.db)
        try await placeVolume(volume, on: agentId, using: app.db)
        return volume
    }

    private func report(
        agentId: String,
        vms: [ObservedVMState] = [],
        volumes: [ObservedVolumeState]
    ) -> ObservedStateReport {
        ObservedStateReport(
            agentId: agentId,
            vms: vms,
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            volumes: volumes
        )
    }

    @Test("A reported size is recorded and surfaced next to the requested one")
    func reportedSizeIsRecorded() async throws {
        try await withVolumeApp { app, user, project in
            let agentId = try await self.registerAgent(app: app, named: "observed-size-agent")
            let volume = try await self.makeVolume(
                app: app, user: user, project: project, agentId: agentId, size: 3 << 30)

            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: agentId,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volume.id!,
                            present: true,
                            storagePath: "/var/lib/strato/volumes/v/volume.qcow2",
                            sizeBytes: 3 << 30,
                            observedGeneration: 1)
                    ]))

            let stored = try #require(try await Volume.find(volume.id!, on: app.db))
            #expect(stored.observedSizeBytes == 3 << 30)
            let response = VolumeResponse(from: stored)
            #expect(response.size == 3 << 30)
            #expect(response.observedSize == 3 << 30)
            #expect(response.observedSizeFormatted == response.sizeFormatted)
        }
    }

    /// End-to-end through report application for STR-242 and STR-247. The agent
    /// may report the VM's target generation and `Running` in the same heartbeat
    /// that still shows the image-backed root disk at its 112 MiB source size.
    /// That report must not settle the start. A later report for an Ubuntu Noble
    /// image whose native 3.5 GiB size exceeds the 2 GiB request is healthy,
    /// however, and must complete the same VM mutation automatically.
    @Test("VM start requires at least the requested boot volume size")
    func vmStartRequiresAtLeastRequestedBootVolumeSize() async throws {
        try await withVolumeApp { app, user, project in
            let agentId = try await self.registerAgent(app: app, named: "rapid-start-agent")
            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "rapid-start-vm", project: project)
            vm.hypervisorId = agentId
            vm.setStatus(.created)
            vm.desiredStatus = .running
            vm.generation = 2
            vm.observedGeneration = 1
            vm.convergenceDeadline = Date().addingTimeInterval(300)
            try await vm.save(on: app.db)

            let requestedSize: Int64 = 2 << 30
            let sourceSize: Int64 = 112 << 20
            let materializedSize: Int64 = 3_758_096_384
            let bootVolume = try await self.makeVolume(
                app: app,
                user: user,
                project: project,
                agentId: agentId,
                size: requestedSize,
                observedSizeBytes: nil,
                generation: 1,
                observedGeneration: 0)
            bootVolume.volumeType = .boot
            bootVolume.$vm.id = try vm.requireID()
            bootVolume.deviceName = "disk0"
            bootVolume.bootOrder = 0
            try await bootVolume.save(on: app.db)

            let vmObservation = ObservedVMState(
                vmId: try vm.requireID(),
                status: .running,
                observedGeneration: 2)
            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: agentId,
                    vms: [vmObservation],
                    volumes: [
                        ObservedVolumeState(
                            volumeId: try bootVolume.requireID(),
                            present: true,
                            storagePath: "/var/lib/strato/volumes/root/volume.qcow2",
                            sizeBytes: sourceSize,
                            attachedVMId: try vm.requireID(),
                            observedGeneration: 0,
                            convergencePhase: "resizing")
                    ]))

            let pending = try #require(try await VM.find(try vm.requireID(), on: app.db))
            #expect(pending.observedGeneration == 1)
            #expect(pending.status == .created)
            #expect(pending.conditions.converged == false)
            #expect(pending.conditions.phase?.contains("observed \(sourceSize)") == true)

            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: agentId,
                    vms: [vmObservation],
                    volumes: [
                        ObservedVolumeState(
                            volumeId: try bootVolume.requireID(),
                            present: true,
                            storagePath: "/var/lib/strato/volumes/root/volume.qcow2",
                            sizeBytes: materializedSize,
                            attachedVMId: try vm.requireID(),
                            observedGeneration: 1)
                    ]))

            let settled = try #require(try await VM.find(try vm.requireID(), on: app.db))
            #expect(settled.observedGeneration == 2)
            #expect(settled.status == .running)
            #expect(settled.conditions.phase == nil)
            #expect(settled.conditions.converged)

            let settledVolume = try #require(
                try await Volume.find(try bootVolume.requireID(), on: app.db))
            #expect(settledVolume.size == requestedSize)
            #expect(settledVolume.observedSizeBytes == materializedSize)
            #expect(settledVolume.status == .attached)
            #expect(settledVolume.conditions.converged)
        }
    }

    /// The bug the column exists for. A grow refused because the volume's guest
    /// is still running leaves the desired size persisted and the image
    /// untouched, and the response has to say both numbers.
    @Test("A refused grow reports the size on disk, not the size asked for")
    func refusedGrowReportsTheSizeOnDisk() async throws {
        try await withVolumeApp { app, user, project in
            let agentId = try await self.registerAgent(app: app, named: "refused-grow-agent")
            // Resized to 3 GiB: generation 3 accepted, agent still at 2.
            let volume = try await self.makeVolume(
                app: app, user: user, project: project, agentId: agentId,
                size: 3 << 30, observedSizeBytes: 1 << 30, generation: 3, observedGeneration: 2)

            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: agentId,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volume.id!,
                            present: true,
                            storagePath: "/var/lib/strato/volumes/v/volume.qcow2",
                            sizeBytes: 1 << 30,
                            observedGeneration: 2,
                            lastError: "refusing to grow volume: it is attached to a running VM",
                            failedGeneration: 3)
                    ]))

            let stored = try #require(try await Volume.find(volume.id!, on: app.db))
            let response = VolumeResponse(from: stored)
            #expect(response.size == 3 << 30)
            #expect(response.observedSize == 1 << 30)
            #expect(response.observedSizeFormatted != response.sizeFormatted)
            // And the conditions still say the grow has not landed, so the two
            // readings of "did it work?" agree.
            #expect(stored.isConverged == false)
        }
    }

    /// The echo rule the applied I/O ceilings already follow: nil is "the agent
    /// said nothing", never "zero bytes". A pre-v38 agent reports no size at
    /// all, and writing that through would replace a real measurement with a
    /// blank on every heartbeat.
    @Test("An agent that reports no size does not clear the recorded one")
    func silentAgentDoesNotClearTheRecordedSize() async throws {
        try await withVolumeApp { app, user, project in
            let agentId = try await self.registerAgent(app: app, named: "silent-size-agent")
            let volume = try await self.makeVolume(
                app: app, user: user, project: project, agentId: agentId,
                size: 3 << 30, observedSizeBytes: 3 << 30)

            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: agentId,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volume.id!,
                            present: true,
                            storagePath: "/var/lib/strato/volumes/v/volume.qcow2",
                            sizeBytes: nil,
                            observedGeneration: 1)
                    ]))

            let stored = try #require(try await Volume.find(volume.id!, on: app.db))
            #expect(stored.observedSizeBytes == 3 << 30)
        }
    }

    /// Nothing invents a size, either: a volume no agent has reported on has a
    /// null column and a null response field, rather than an echo of `size`.
    @Test("A volume no agent has reported on has no observed size")
    func unreportedVolumeHasNoObservedSize() async throws {
        try await withVolumeApp { app, user, project in
            let agentId = try await self.registerAgent(app: app, named: "unreported-size-agent")
            let volume = try await self.makeVolume(
                app: app, user: user, project: project, agentId: agentId, size: 3 << 30)

            let response = VolumeResponse(from: volume)
            #expect(response.observedSize == nil)
            #expect(response.observedSizeFormatted == nil)
        }
    }
}
