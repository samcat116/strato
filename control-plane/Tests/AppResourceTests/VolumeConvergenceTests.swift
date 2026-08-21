import Testing
import Vapor
import VaporTesting
import StratoShared
import AppTestSupport
@testable import App

/// Volumes on the reconciliation loop, end to end (ADR 0001 stage 5, STR-148).
///
/// Three properties this suite exists to pin, because each is an argument the
/// conversion rests on rather than something the type system enforces:
///
/// * a mutation is *accepted*, not performed — 202 with a bumped
///   `targetGeneration` and a `resource_events` row, and no imperative RPC;
/// * a volume's row is removed only when its agent stops listing it, so a
///   delete can be re-driven indefinitely without ever orphaning bytes;
/// * an observed report that says *nothing* about volumes deletes nothing.
@Suite("Volume Convergence Tests", .serialized)
final class VolumeConvergenceTests {

    private func withVolumeApp(
        _ test: (Application, TestDataBuilder, User, Project) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)

            let builder = TestDataBuilder(db: app.testPostgres)
            let user = try await builder.createUser(
                username: "convuser",
                email: "conv@example.com",
                displayName: "Convergence User",
                isSystemAdmin: true
            )
            let org = try await builder.createOrganization(name: "Conv Org")
            let project = try await builder.createProject(
                name: "Conv Project", description: "Volume convergence", organization: org)

            try await test(app, builder, user, project)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func registerAgent(
        app: Application, named name: String, protocolVersion: Int = WireProtocol.currentVersion
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: name,
            hostname: "\(name).test",
            version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: protocolVersion
        )
        let project = try #require(try await Project.all(on: app.testPostgres).first)
        let siteID = try await TestDataBuilder(db: app.testPostgres).placementSite(for: project).requireID()
        let orgID = try await Organization.all(on: app.testPostgres).first?.id
        let uuid = try await app.agentService.registerAgent(
            message, agentName: name, siteID: siteID,
            organizationScope: orgID.map { .organization($0) })
        return uuid.uuidString
    }

    @discardableResult
    private func makeVolume(
        on app: Application,
        user: User,
        project: Project,
        agentId: String?,
        name: String = "vol",
        size: Int64 = 10 << 30,
        status: VolumeStatus = .available,
        desired: DesiredVolumeStatus = .present,
        generation: Int64 = 1,
        observedGeneration: Int64 = 1,
        storagePath: String? = "/var/lib/strato/volumes/v/volume.qcow2"
    ) async throws -> Volume {
        let volume = Volume(
            name: name,
            description: "",
            projectID: project.id!, environment: "development",
            size: size,
            status: status,
            desiredStatus: desired,
            generation: generation,
            observedGeneration: observedGeneration,
            createdByID: user.id!
        )
        try await volume.save(on: app.testPostgres)
        try await placeVolume(
            volume,
            on: agentId,
            at: storagePath,
            state: storagePath == nil ? .provisioning : .healthy,
            using: app.testPostgres
        )
        return volume
    }

    private func report(
        agentId: String, volumes: [ObservedVolumeState]?
    ) -> ObservedStateReport {
        ObservedStateReport(
            agentId: agentId,
            vms: [],
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            volumes: volumes
        )
    }

    // MARK: - Assembly

    @Test("A volume placed on an agent rides that agent's sync")
    func volumeIsAssembledForItsAgent() async throws {
        try await withVolumeApp { app, _, user, project in
            let agentId = try await registerAgent(app: app, named: "assemble-agent")
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId, size: 20 << 30)

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let entry = try #require(message.volumes.first)
            #expect(entry.volumeId == volume.id)
            #expect(entry.sizeBytes == 20 << 30)
            #expect(entry.format == "qcow2")
            #expect(entry.desiredStatus == .present)
            #expect(entry.attachment == nil)
            // Neither the pool nor the path travels: placement is expressed by
            // whose sync the entry is on, and the agent owns path layout.
            #expect(entry.source == nil)
        }
    }

    @Test("A desired attachment is projected from the VM link, not the status")
    func attachmentIsProjectedFromTheVMLink() async throws {
        try await withVolumeApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "attach-agent")
            var vm = try await builder.createVM(name: "attach-vm", project: project)
            vm.hypervisorId = agentId
            try await vm.save(on: app.testPostgres)

            let boot = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId, name: "attach-boot"
            ).replacing(volumeType: .boot, vmID: vm.id, deviceName: "disk0", bootOrder: 0)
            try await boot.save(on: app.testPostgres)

            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId
            ).replacing(
                status: .available, vmID: vm.id, deviceName: "disk1", bootOrder: 2,
                readonly: true)
            // Deliberately *not* `.attached`: the projection must read the
            // desired attachment, or the two projections of one fact (this and
            // `VMSpec.volumes`) can disagree.
            try await volume.save(on: app.testPostgres)

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let attachment = try #require(
                message.volumes.first { $0.volumeId == volume.id }?.attachment)
            #expect(attachment.vmId == vm.id)
            #expect(attachment.deviceName.rawValue == "disk1")
            #expect(attachment.readonly)
            #expect(attachment.bootOrder == 2)
        }
    }

    @Test("Only the VM host receives a replicated volume's attachment intent")
    func attachmentIsScopedToVMPlacement() async throws {
        try await withVolumeApp { app, builder, user, project in
            let vmAgentID = try await registerAgent(app: app, named: "attachment-vm-host")
            let storageOnlyAgentID = try await registerAgent(app: app, named: "attachment-storage-only")
            var vm = try await builder.createVM(name: "attachment-target", project: project)
            vm.hypervisorId = vmAgentID
            try await vm.save(on: app.testPostgres)

            let boot = try await makeVolume(
                on: app, user: user, project: project, agentId: vmAgentID,
                name: "attachment-target-boot"
            ).replacing(volumeType: .boot, vmID: vm.id, deviceName: "disk0", bootOrder: 0)
            try await boot.save(on: app.testPostgres)

            let initialVolume = try await makeVolume(
                on: app, user: user, project: project, agentId: vmAgentID)
            let volume = initialVolume.replacing(vmID: vm.id, deviceName: "disk1")
            try await placeVolume(volume, on: storageOnlyAgentID, using: app.testPostgres)
            try await volume.save(on: app.testPostgres)

            let vmHostMessage = try await app.desiredStateAssembler.assemble(agentId: vmAgentID)
            let vmHostEntry = try #require(vmHostMessage.volumes.first { $0.volumeId == volume.id })
            #expect(vmHostEntry.attachment?.vmId == vm.id)

            let storageOnlyMessage = try await app.desiredStateAssembler.assemble(
                agentId: storageOnlyAgentID)
            let storageOnlyEntry = try #require(
                storageOnlyMessage.volumes.first { $0.volumeId == volume.id })
            #expect(storageOnlyEntry.attachment == nil)
        }
    }

    @Test("A clone's source rides the entry as a create strategy")
    func cloneSourceIsACreateStrategy() async throws {
        try await withVolumeApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "clone-agent")
            let source = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId, name: "clone-source",
                status: .attached
            ).replacing(vmID: nil, deviceName: "disk1")
            let sourceVM = try await builder.createVM(name: "clone-source-vm", project: project)
            let attachedSource = source.replacing(vmID: sourceVM.id)
            try await attachedSource.save(on: app.testPostgres)
            let clone = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId, name: "clone-target",
                status: .creating, observedGeneration: 0
            ).replacing(sourceVolumeID: source.id)
            try await clone.save(on: app.testPostgres)

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let entry = try #require(message.volumes.first { $0.volumeId == clone.id })
            #expect(entry.source?.kind == DesiredVolumeSource.clone)
            #expect(entry.source?.sourceVolumeId == attachedSource.id)
            #expect(entry.source?.sourceVMId == sourceVM.id)
        }
    }

    // MARK: - Ingesting the observed report

    @Test("An observed volume settles its status, attachment, and replica")
    func observedVolumeSettles() async throws {
        try await withVolumeApp { app, _, user, project in
            let agentId = try await registerAgent(app: app, named: "observe-agent")
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId,
                status: .creating, observedGeneration: 0, storagePath: nil)
            let volumeID = try #require(volume.id)

            _ = try await app.observedStateApplier.apply(
                report(
                    agentId: agentId,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volumeID, present: true,
                            attachment: .file(path: "/agent/chosen/path.qcow2", format: .qcow2),
                            observedGeneration: 1)
                    ]))

            let settled = try await #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(settled.status == .available)
            #expect(settled.observedGeneration == 1)
            #expect(settled.conditions.converged)

            let replica = try await LegacyVolumeReplicaStore.replicas(
                volumeIDs: [volumeID],
                on: app.testPostgres
            ).first
            #expect(
                replica?.diskAttachment
                    == .file(path: "/agent/chosen/path.qcow2", format: .qcow2))
            #expect(replica?.state == .healthy)
            #expect(replica?.generation == 1)
        }
    }

    @Test("A typed attachment is persisted and echoed into the VM spec verbatim")
    func typedAttachmentRoundTripsThroughControlPlane() async throws {
        try await withVolumeApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "typed-attachment-agent")
            var vm = try await builder.createVM(name: "typed-attachment-vm", project: project)
            vm.hypervisorId = agentId
            try await vm.save(on: app.testPostgres)

            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId,
                name: "typed-attachment-root", status: .creating, observedGeneration: 0,
                storagePath: nil
            ).replacing(
                volumeType: .boot, vmID: try vm.requireID(), deviceName: "disk0", bootOrder: 0)
            try await volume.save(on: app.testPostgres)
            let volumeID = try volume.requireID()
            let attachment = DiskAttachment.rbd(
                pool: "volumes", image: volumeID.uuidString, user: "client.project",
                monHosts: ["10.0.0.10:6789", "10.0.0.11:6789"])

            _ = try await app.observedStateApplier.apply(
                report(
                    agentId: agentId,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volumeID, present: true, attachment: attachment,
                            observedGeneration: 1)
                    ]))

            let replica = try #require(
                try await LegacyVolumeReplicaStore.replicas(
                    volumeIDs: [volumeID],
                    on: app.testPostgres
                ).first)
            #expect(replica.diskAttachment == attachment)

            let desired = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let vmEntry = try #require(desired.vms.first { $0.vmId == vm.id })
            #expect(vmEntry.spec.volumes.first?.attachment == attachment)
        }
    }

    @Test("Logical convergence waits for every required replica and preserves peer failures")
    func logicalConvergenceAggregatesReplicas() async throws {
        try await withVolumeApp { app, _, user, project in
            let firstAgentID = try await registerAgent(app: app, named: "converge-replica-a")
            let secondAgentID = try await registerAgent(app: app, named: "converge-replica-b")
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: firstAgentID,
                generation: 2, observedGeneration: 1)
            try await placeVolume(volume, on: secondAgentID, using: app.testPostgres)
            let volumeID = try volume.requireID()

            _ = try await app.observedStateApplier.apply(
                report(
                    agentId: firstAgentID,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volumeID, present: true,
                            attachment: .file(path: "/replica-a", format: .qcow2),
                            observedGeneration: 2)
                    ]))

            var stored = try #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(stored.observedGeneration == 1)
            #expect(!stored.conditions.converged)
            #expect(stored.convergencePhase == "waiting for replicas")

            _ = try await app.observedStateApplier.apply(
                report(
                    agentId: secondAgentID,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volumeID, present: true,
                            attachment: .file(path: "/replica-b", format: .qcow2),
                            observedGeneration: 2, lastError: "replica write failed",
                            failedGeneration: 2)
                    ]))

            stored = try #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(stored.observedGeneration == 1)
            #expect(stored.conditions.degraded?.reason == "replica write failed")

            // A heartbeat from the already-settled peer cannot erase another
            // required replica's failure.
            _ = try await app.observedStateApplier.apply(
                report(
                    agentId: firstAgentID,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volumeID, present: true,
                            attachment: .file(path: "/replica-a", format: .qcow2),
                            observedGeneration: 2)
                    ]))
            stored = try #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(stored.conditions.degraded?.reason == "replica write failed")
            #expect(!stored.conditions.converged)

            _ = try await app.observedStateApplier.apply(
                report(
                    agentId: secondAgentID,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volumeID, present: true,
                            attachment: .file(path: "/replica-b", format: .qcow2),
                            observedGeneration: 2)
                    ]))
            stored = try #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(stored.observedGeneration == 2)
            #expect(stored.conditions.converged)
            #expect(stored.conditions.degraded == nil)
        }
    }

    @Test("A reported attachment settles the volume as attached")
    func observedAttachmentSettles() async throws {
        try await withVolumeApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "observe-attach-agent")
            let vm = try await builder.createVM(name: "observed-vm", project: project)
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId,
                status: .available, generation: 2, observedGeneration: 1
            ).replacing(vmID: vm.id, deviceName: "disk1")
            try await volume.save(on: app.testPostgres)
            let volumeID = try #require(volume.id)

            _ = try await app.observedStateApplier.apply(
                report(
                    agentId: agentId,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volumeID, present: true,
                            attachment: .file(path: "/p", format: .qcow2),
                            attachedVMId: vm.id, observedGeneration: 2)
                    ]))

            let settled = try await #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(settled.status == .attached)
            #expect(settled.attachedAgentId == agentId)
            #expect(settled.conditions.converged)
        }
    }

    @Test("A reported convergence failure degrades the volume with its reason")
    func observedFailureDegrades() async throws {
        try await withVolumeApp { app, _, user, project in
            let agentId = try await registerAgent(app: app, named: "failing-agent")
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId,
                status: .creating, generation: 3, observedGeneration: 0, storagePath: nil)
            let volumeID = try #require(volume.id)

            _ = try await app.observedStateApplier.apply(
                report(
                    agentId: agentId,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volumeID, present: false, observedGeneration: 0,
                            lastError: "no space left on device", failedGeneration: 3)
                    ]))

            let degraded = try await #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(degraded.status == .error)
            #expect(degraded.conditions.degraded?.reason == "no space left on device")
            #expect(degraded.conditions.degraded?.sinceGeneration == 3)
        }
    }

    @Test("A stale volume failure cannot overwrite a newer deletion")
    func staleFailureCannotOverwriteDelete() async throws {
        try await withVolumeApp { app, _, user, project in
            let agentId = try await registerAgent(app: app, named: "stale-volume-agent")
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId,
                status: .creating, generation: 10, observedGeneration: 9, storagePath: nil
            ).replacing(convergenceDeadline: Date().addingTimeInterval(120))
            try await volume.save(on: app.testPostgres)
            let volumeID = try #require(volume.id)
            let stale = try #require(try await Volume.find(volumeID, on: app.testPostgres))
            let deleteCopy = try #require(try await Volume.find(volumeID, on: app.testPostgres))

            let result = try await app.resourceMutation.acceptValue(
                .delete, on: deleteCopy, actor: .user(try user.requireID()),
                dispatch: .directResolution { _ in false }, on: app.testPostgres, app: app
            ) { current, db in
                let stamped = try await ResourceFinalizerService.stampForDeletion(current, on: db)
                return stamped.replacingDesiredStatus(.absent)
            }
            #expect(result.accepted.targetGeneration == 11)

            let failure = try await ResourceConvergence.recordValueFailure(
                stale, mutation: .resize, reason: "obsolete resize failure",
                telemetryReason: "convergence_failed", on: app.testPostgres)
            #expect(failure.outcome == .superseded(actualGeneration: 11))

            let stored = try #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(stored.generation == 11)
            #expect(stored.desiredStatus == .absent)
            #expect(stored.convergenceDeadline != nil)
            #expect(stored.errorMessage == nil)
            #expect(stored.failedGeneration == nil)

            await app.backgroundTasks.drain(timeout: .seconds(10))
        }
    }

    /// The STR-191 shape, which the test above does not reach: there the agent
    /// had never applied generation 3, so `converged` was false on the
    /// generation clause alone. Here it *has* — a resize planned at a generation
    /// an earlier work item already applied — and only the failure clause keeps
    /// the two conditions from both answering.
    @Test("A resize that fails at an already-applied generation un-converges the volume")
    func failureAtAppliedGenerationUnconverges() async throws {
        try await withVolumeApp { app, _, user, project in
            let agentId = try await registerAgent(app: app, named: "drift-agent")
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId,
                status: .available, generation: 3, observedGeneration: 3)
            let volumeID = try #require(volume.id)

            _ = try await app.observedStateApplier.apply(
                report(
                    agentId: agentId,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volumeID, present: true,
                            attachment: .file(path: "/p", format: .qcow2),
                            observedGeneration: 3,
                            lastError: "no space left on device", failedGeneration: 3)
                    ]))

            let degraded = try await #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(!degraded.conditions.converged)
            #expect(degraded.conditions.degraded?.sinceGeneration == 3)

            // …and the bytes are still at rest, so the two verbs that copy them
            // keep working. Gating those on convergence would lock the volume out
            // permanently: nothing clears a failed resize's generation.
            #expect(degraded.bytesAtRest)
            #expect(degraded.canSnapshot)
            #expect(degraded.canClone)
        }
    }

    /// `deviceName` is the *desired* slot, read straight back out by the
    /// assembler. An observation that disagrees must not overwrite it: doing so
    /// would replace what the user asked for with what the agent happens to
    /// have, and — being a bare field write with no generation bump — would do
    /// it without the agent ever noticing the goalposts moved. The disagreement
    /// is the loop working; the agent plans detach-then-attach to correct it.
    @Test("A reported device name never overwrites the desired slot")
    func reportedDeviceNameDoesNotOverwriteDesire() async throws {
        try await withVolumeApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "slot-agent")
            let vm = try await builder.createVM(name: "slot-vm", project: project)
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId,
                status: .available, generation: 2, observedGeneration: 1
            ).replacing(vmID: vm.id, deviceName: "disk1")
            try await volume.save(on: app.testPostgres)
            let volumeID = try #require(volume.id)

            _ = try await app.observedStateApplier.apply(
                report(
                    agentId: agentId,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volumeID, present: true,
                            attachment: .file(path: "/p", format: .qcow2),
                            attachedVMId: vm.id, observedGeneration: 2)
                    ]))

            let after = try await #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(after.deviceName == "disk1")
            #expect(after.generation == 2)
        }
    }

    /// Full-list omission is how a deletion is confirmed — and the only way.
    @Test("Omitting a terminating volume clears its finalizer and reaps the row")
    func omissionConfirmsDeletion() async throws {
        try await withVolumeApp { app, _, user, project in
            let agentId = try await registerAgent(app: app, named: "reap-agent")
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId,
                desired: .absent, generation: 2, observedGeneration: 1
            ).replacing(finalizers: [ResourceFinalizer.agentAbsent.rawValue])
            try await volume.save(on: app.testPostgres)
            let volumeID = try #require(volume.id)

            _ = try await app.observedStateApplier.apply(report(agentId: agentId, volumes: []))

            #expect(try await Volume.find(volumeID, on: app.testPostgres) == nil)
            // The reap appends the terminal event a client polling the façade
            // with its `mutationId` is waiting for.
            let terminal = try await ResourceEvent.latest(
                .completed, resourceKind: .volume, resourceID: volumeID, on: app.testPostgres)
            #expect(terminal != nil)
        }
    }

    @Test("A terminating volume waits for inactive physical replicas")
    func physicalReplicaOmissionWaitsForInactiveCopy() async throws {
        try await withVolumeApp { app, _, user, project in
            let firstAgentID = try await registerAgent(app: app, named: "reap-replica-a")
            let secondAgentID = try await registerAgent(app: app, named: "reap-replica-b")
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: firstAgentID,
                desired: .absent, generation: 2, observedGeneration: 1
            ).replacing(finalizers: [ResourceFinalizer.agentAbsent.rawValue])
            try await placeVolume(
                volume, on: secondAgentID, at: "/volumes/replica-b.qcow2", state: .faulted,
                using: app.testPostgres)
            try await volume.save(on: app.testPostgres)
            let volumeID = try volume.requireID()

            let secondDesiredState = try await app.desiredStateAssembler.assemble(
                agentId: secondAgentID)
            #expect(
                secondDesiredState.volumes.contains {
                    $0.volumeId == volumeID && $0.desiredStatus == .absent
                })
            #expect(
                Set(try await volume.placementAgentIDs(on: app.testPostgres))
                    == Set([firstAgentID, secondAgentID]))

            _ = try await app.observedStateApplier.apply(
                report(agentId: firstAgentID, volumes: []))
            #expect(try await Volume.find(volumeID, on: app.testPostgres) != nil)
            #expect(try await VolumeService.agentIDs(holding: volume, on: app.testPostgres).isEmpty)
            #expect(
                try await VolumeService.agentIDsWithPhysicalReplicas(of: volume, on: app.testPostgres)
                    == [secondAgentID])

            _ = try await app.observedStateApplier.apply(
                report(agentId: secondAgentID, volumes: []))
            #expect(try await Volume.find(volumeID, on: app.testPostgres) == nil)
        }
    }

    /// The headline safety test of the whole conversion. An agent below wire
    /// v31 omits `volumes` entirely; reading that silence as an authoritative
    /// empty list would reap every terminating volume row it holds and error
    /// every live one.
    @Test("A report with no volumes field deletes nothing and errors nothing")
    func nilVolumesReportIsInert() async throws {
        try await withVolumeApp { app, _, user, project in
            let agentId = try await registerAgent(app: app, named: "silent-agent")
            let live = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId, name: "live")
            let terminating = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId, name: "terminating",
                desired: .absent, generation: 2, observedGeneration: 1
            ).replacing(finalizers: [ResourceFinalizer.agentAbsent.rawValue])
            try await terminating.save(on: app.testPostgres)

            _ = try await app.observedStateApplier.apply(report(agentId: agentId, volumes: nil))

            let liveAfter = try await #require(try await Volume.find(live.id, on: app.testPostgres))
            #expect(liveAfter.status == .available)
            #expect(try await Volume.find(terminating.id, on: app.testPostgres) != nil)
        }
    }

    /// An empty list from an agent that *does* speak volume sync is a real
    /// statement — "I hold no volumes" — and is what confirms the deletion in
    /// `omissionConfirmsDeletion` above. This pins the contrast: same code
    /// path, opposite outcome, decided entirely by nil vs `[]`.
    @Test("An empty volumes list errors a live volume the agent should hold")
    func emptyVolumesListIsAuthoritative() async throws {
        try await withVolumeApp { app, _, user, project in
            let agentId = try await registerAgent(app: app, named: "empty-list-agent")
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId)
            let volumeID = try #require(volume.id)

            _ = try await app.observedStateApplier.apply(report(agentId: agentId, volumes: []))

            let after = try await #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(after.status == .error)
        }
    }

    /// A volume no agent has ever confirmed is not an error: it may simply be
    /// waiting for its first sync to arrive. Without this, every create would
    /// flash red before it went green.
    @Test("A never-confirmed volume missing from a report is not errored")
    func neverConfirmedVolumeIsNotErrored() async throws {
        try await withVolumeApp { app, _, user, project in
            let agentId = try await registerAgent(app: app, named: "fresh-agent")
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId,
                status: .creating, observedGeneration: 0, storagePath: nil)
            let volumeID = try #require(volume.id)

            _ = try await app.observedStateApplier.apply(report(agentId: agentId, volumes: []))

            let after = try await #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(after.status == .creating)
        }
    }

    // MARK: - Mutations are accepted, not performed

    @Test("Attaching bumps the generation and records an attach event")
    func attachIsAcceptedAndAttributed() async throws {
        try await withVolumeApp { app, builder, user, project in
            let agentId = try await registerAgent(app: app, named: "mutation-agent")
            var vm = try await builder.createVM(name: "mutation-vm", project: project)
            vm.hypervisorId = agentId
            try await vm.save(on: app.testPostgres)
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId, generation: 4)
            let volumeID = try #require(volume.id)
            let vmID = try #require(vm.id)

            let result = try await app.resourceMutation.acceptValue(
                .attach, on: volume, actor: .user(try user.requireID()), dispatch: .stateSync,
                on: app.testPostgres, app: app
            ) { @Sendable current, _ in
                current.replacing(vmID: vmID, deviceName: "disk1")
            }

            #expect(result.accepted.targetGeneration == 5)

            let stored = try await #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(stored.generation == 5)
            #expect(stored.vmID == vmID)
            // Not converged: the agent has not seen generation 5 yet, which is
            // exactly what a client watching `conditions` should observe.
            #expect(stored.conditions.converged == false)
            #expect(stored.conditions.targetGeneration == 5)
            // A live deadline is what says a mutation is outstanding.
            #expect(stored.convergenceDeadline != nil)

            let event = try await #require(
                try await ResourceEvent.latest(
                    .requested, resourceKind: .volume, resourceID: volumeID, on: app.testPostgres))
            #expect(event.mutation == .attach)
            #expect(event.targetGeneration == 5)
        }
    }

    @Test("A delete stamps the finalizer before marking the volume absent")
    func deleteStampsThenMarks() async throws {
        try await withVolumeApp { app, _, user, project in
            let agentId = try await registerAgent(app: app, named: "delete-agent")
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId, generation: 2)
            let volumeID = try #require(volume.id)

            _ = try await app.resourceMutation.acceptValue(
                .delete, on: volume, actor: .user(try user.requireID()), dispatch: .stateSync,
                on: app.testPostgres, app: app
            ) { @Sendable current, db in
                let stamped = try await ResourceFinalizerService.stampForDeletion(current, on: db)
                return stamped.replacingDesiredStatus(.absent)
            }

            let stored = try await #require(try await Volume.find(volumeID, on: app.testPostgres))
            #expect(stored.desiredStatus == .absent)
            #expect(stored.finalizers == [ResourceFinalizer.agentAbsent.rawValue])
            // The row survives the request: only the agent's confirmation of
            // absence removes it.
            #expect(stored.isTerminating)
        }
    }

    @Test("Reaping a boot volume clears its parent VM finalizer")
    func bootVolumeReapAcknowledgesParent() async throws {
        try await withVolumeApp { app, builder, user, project in
            var vm = try await builder.createVM(name: "boot-owner", project: project)
            let vmID = try vm.requireID()
            vm.setDesiredStatus(.absent)
            vm.finalizers = [
                ResourceFinalizer.agentAbsent.rawValue,
                ResourceFinalizer.bootVolumeAbsent.rawValue,
            ]
            try await vm.save(on: app.testPostgres)

            let boot = Volume(
                name: "boot", description: "", projectID: try project.requireID(),
                environment: vm.environment, size: vm.disk, volumeType: .boot,
                desiredStatus: .absent, createdByID: try user.requireID(), vmID: vmID,
                deviceName: "disk0", bootOrder: 0)
            try await boot.save(on: app.testPostgres)

            #expect(try await Volume.reap(boot, on: app.testPostgres, app: app))
            #expect(try await Volume.find(try boot.requireID(), on: app.testPostgres) == nil)

            let parent = try #require(try await VM.find(vmID, on: app.testPostgres))
            #expect(parent.finalizers == [ResourceFinalizer.agentAbsent.rawValue])
        }
    }

    /// Reaping a volume must revoke its snapshots' bindings *before* the FK
    /// cascade takes those rows away — the same read-before-delete ordering the
    /// VM and sandbox reaps have.
    @Test("Reaping a volume revokes its snapshot bindings before the cascade")
    func reapRevokesSnapshotBindings() async throws {
        try await withVolumeApp { app, _, user, project in
            let agentId = try await registerAgent(app: app, named: "binding-agent")
            let volume = try await makeVolume(
                on: app, user: user, project: project, agentId: agentId,
                desired: .absent, generation: 2)
            let volumeID = try #require(volume.id)

            let snapshot = VolumeSnapshot(
                name: "snap", description: "", volumeID: volumeID,
                projectID: try project.requireID(), environment: "development", size: 1 << 30,
                createdByID: try user.requireID())
            try await snapshot.save(on: app.testPostgres)
            let snapshotID = try #require(snapshot.id)
            try await RoleBindingService.grant(
                principalType: .user, principalID: try user.requireID(), role: .admin,
                nodeType: .volumeSnapshot, nodeID: snapshotID, createdBy: user.id, on: app.testPostgres)

            #expect(try await Volume.reap(volume, on: app.testPostgres, app: app))
            #expect(try await Volume.find(volumeID, on: app.testPostgres) == nil)

            let remaining = try await LegacyRoleBindingStore.bindings(
                nodeType: IAMNodeType.volumeSnapshot.rawValue,
                nodeID: snapshotID,
                on: app.testPostgres).count
            #expect(remaining == 0)
        }
    }
}
