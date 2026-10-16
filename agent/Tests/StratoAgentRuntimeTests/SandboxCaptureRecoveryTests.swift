import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Testing
@testable import StratoAgentRuntime

@Suite("sandbox capture recovery dispatch")
struct SandboxCaptureRecoveryTests {
    @Test(arguments: [false, true])
    func disabledRuntimeKeepsProofReservations(legacyDebris: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = SandboxSuspensionRecord(
            sandboxId: UUID(), snapshotId: UUID(), generation: 4, activityEpoch: 0, jailUID: 100000,
            spec: SandboxSpec(image: "test", cpus: 1, memoryBytes: 128 * 1024 * 1024))
        let proof = SandboxValidationProof(
            id: UUID(), permit: UUID(), jailUID: 100001,
            reservation: HostReservation(cpus: 2, memoryBytes: 512 * 1024 * 1024, diskBytes: 1024 * 1024 * 1024))
        try SandboxValidationProofStore(directory: root.path + "/suspension-validation").save(proof)
        if legacyDebris {
            try FileManager.default.createDirectory(
                atPath: root.path + "/warm-template-suspend-proof-unrecorded", withIntermediateDirectories: true)
        }
        let agent = Agent(
            agentID: "disabled-proof", webSocketURL: "ws://localhost/agent/ws",
            configuration: runtimeTestConfiguration(
                path: root.path, simulation: SimulationConfig(enabled: true, memoryMB: 4096)),
            logger: Logger(label: "disabled-proof"))
        await agent.seedCaptureRecovery(runtime: CaptureRecoveryRuntime(record: record), record: record)
        await agent.disableCaptureRecoveryRuntime()
        let raw = await agent.rawHostCapacitySnapshot()
        let resources = await agent.getAgentResources()
        if legacyDebris {
            #expect(!raw.inventoryKnown)
            #expect(!raw.diskInventoryKnown)
            #expect(resources.availableCPU == 0)
            #expect(resources.availableMemory == 0)
            #expect(resources.availableDisk == 0)
        } else {
            #expect(raw.inventoryKnown)
            #expect(raw.diskInventoryKnown)
            #expect(raw.workloadReservations[proof.proofId] == proof.reservation)
            #expect(raw.reserved.memoryBytes == 768 * 1024 * 1024)
        }
        try await agent.eventLoopGroup.shutdownGracefully()
    }

    @Test(arguments: [false, true])
    func validationProofInventoryControlsAllCapacity(unknown: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let record = SandboxSuspensionRecord(
            sandboxId: id, snapshotId: UUID(), generation: 4, activityEpoch: 0, jailUID: 100000,
            spec: SandboxSpec(image: "test", cpus: 1, memoryBytes: 128 * 1024 * 1024))
        let runtime = CaptureRecoveryRuntime(record: record)
        let proof = HostReservation(cpus: 2, memoryBytes: 512 * 1024 * 1024, diskBytes: 1024 * 1024 * 1024)
        await runtime.setProofInventory(["validation-proof": proof], unknown: unknown)
        let agent = Agent(
            agentID: "proof-inventory", webSocketURL: "ws://localhost/agent/ws",
            configuration: runtimeTestConfiguration(
                path: root.path, simulation: SimulationConfig(enabled: true, memoryMB: 4096)),
            logger: Logger(label: "proof-inventory"))
        await agent.seedCaptureRecovery(runtime: runtime, record: record)
        let raw = await agent.rawHostCapacitySnapshot()
        let resources = await agent.getAgentResources()
        if unknown {
            #expect(!raw.inventoryKnown)
            #expect(!raw.diskInventoryKnown)
            #expect(resources.availableCPU == 0)
            #expect(resources.availableMemory == 0)
            #expect(resources.availableDisk == 0)
        } else {
            #expect(raw.inventoryKnown)
            #expect(raw.workloadReservations["validation-proof"] == proof)
            #expect(raw.reserved.memoryBytes == 768 * 1024 * 1024)
            #expect(resources.availableMemory == (4096 - 1024 - 768) * 1024 * 1024)
            #expect(raw.reserved.cpuMicroUnits == 3_000_000)
            #expect(raw.reserved.diskBytes >= proof.diskBytes)
        }
        try await agent.eventLoopGroup.shutdownGracefully()
    }

    @Test func failedSuspensionRetainsClaimWhenProofInventoryBecomesUnknown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let spec = SandboxSpec(image: "test", cpus: 1, memoryBytes: 128 * 1024 * 1024)
        let record = SandboxSuspensionRecord(
            sandboxId: id, snapshotId: UUID(), generation: 4, activityEpoch: 0, jailUID: 100000, spec: spec)
        let runtime = CaptureRecoveryRuntime(record: record)
        await runtime.makeInventoryUnknownOnSuspensionFailure()
        let agent = Agent(
            agentID: "failed-proof", webSocketURL: "ws://localhost/agent/ws",
            configuration: runtimeTestConfiguration(
                path: root.path, simulation: SimulationConfig(enabled: true, memoryMB: 4096)),
            logger: Logger(label: "failed-proof"))
        await agent.seedCaptureRecovery(runtime: runtime, record: record)
        let desired = DesiredSandboxState(
            sandboxId: id, spec: spec, desiredStatus: .suspended, generation: 4,
            suspensionStorageBudgetBytes: 1024 * 1024 * 1024)
        let item = ReconcileWorkItem(
            kind: .sandbox, id: id.uuidString, generation: 4, steps: [.shutdown], target: .sandbox(desired))
        await #expect(throws: SandboxSuspensionGuard.GateError.self) {
            try await agent.sandboxReconcileSuspend(item, automatic: false)
        }
        #expect(await agent.hasRetainedCaptureClaim(id))
        let raw = await agent.rawHostCapacitySnapshot()
        #expect(!raw.inventoryKnown)
        #expect(!raw.diskInventoryKnown)
        try await agent.eventLoopGroup.shutdownGracefully()
    }

    @Test(
        arguments: [SandboxSuspensionRecord.Phase.capturing, .resumed],
        [SandboxSuspensionGuestFence.State.preparePending, .prepared, .releasePending])
    func interruptedCaptureBootsOriginalGuest(
        phase: SandboxSuspensionRecord.Phase, state: SandboxSuspensionGuestFence.State
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let spec = SandboxSpec(image: "test", cpus: 1, memoryBytes: 128 * 1024 * 1024)
        var record = SandboxSuspensionRecord(
            sandboxId: id, snapshotId: UUID(), generation: 4, activityEpoch: 0, jailUID: 100000, spec: spec)
        record.phase = phase
        if phase == .resumed {
            let archive = root.appendingPathComponent("archives/checkpoint")
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            for kind in SandboxSnapshotArtifactKind.allCases {
                try Data("fixture-\(kind.rawValue)".utf8).write(to: archive.appendingPathComponent(kind.filename))
            }
            record.checkpoint = try SandboxCheckpointManifest.publish(
                directory: archive.path, sandboxId: id.uuidString, snapshotId: record.snapshotId.uuidString,
                identityNonce: "original-guest", firecrackerVersion: "fixture", guestControlProtocolVersion: 5)
        }
        record.guestFence = SandboxSuspensionGuestFence(
            request: SandboxAutomaticSuspensionFence(
                operationId: UUID(), generation: 4, activityRevision: 1,
                admissionToken: UUID(), guestProtocolVersion: 5), identityNonce: "original-guest")
        record.guestFence?.state = state
        record.guestFence?.guestToken = UUID()
        let runtime = CaptureRecoveryRuntime(record: record)
        let agent = Agent(
            agentID: "capture-recovery", webSocketURL: "ws://localhost/agent/ws",
            configuration: runtimeTestConfiguration(
                path: root.path, simulation: SimulationConfig(enabled: true, memoryMB: 4096)),
            logger: Logger(label: "capture-recovery"))
        await agent.seedCaptureRecovery(runtime: runtime, record: record)
        let desired = DesiredSandboxState(sandboxId: id, spec: spec, desiredStatus: .running, generation: 5)
        let presence = await agent.observedSandboxPresence()
        #expect(presence[id.uuidString] == .managed(.starting))
        let plan = Reconciler.planSandboxes(
            desired: [desired], present: presence, lastApplied: [id.uuidString: 4])
        let item = try #require(plan.items.first)
        #expect(item.generation == 5)
        #expect(item.steps == [.boot])
        try await agent.sandboxReconcileBoot(item)
        #expect(await runtime.bootCount == 1)
        #expect(await runtime.resumeCount == 0)
        #expect(await agent.captureRecoveryRecord(id)?.phase == phase)
        #expect(await agent.captureRecoveryRecord(id)?.guestFence?.blocksWorkloadAdmission == false)
        let recoveredPresence = await agent.observedSandboxPresence()
        let recoveredPlan = Reconciler.planSandboxes(
            desired: [desired], present: recoveredPresence, lastApplied: [id.uuidString: 5])
        #expect(recoveredPresence[id.uuidString] == .managed(.running))
        #expect(recoveredPlan.items.allSatisfy { $0.steps.isEmpty })
        try await agent.eventLoopGroup.shutdownGracefully()
    }
}

private extension Agent {
    func seedCaptureRecovery(runtime: CaptureRecoveryRuntime, record: SandboxSuspensionRecord) {
        sandboxRuntime = runtime
        let backend = MockStorageBackend(
            logger: Logger(label: "capture-recovery-storage"),
            volumeStoragePath: configuration.vmStoragePath + "/volumes")
        storageBackend = backend
        storageBackends = StorageBackendRegistry(
            local: backend, makeCeph: { _ in fatalError("Ceph is not used by this test") })
        var entry = VMManifestEntry(sandboxSpec: record.spec)
        entry.sandboxSuspension = record
        managedSandboxes[record.sandboxId.uuidString] = entry
    }

    func disableCaptureRecoveryRuntime() { sandboxRuntime = nil }

    func hasRetainedCaptureClaim(_ id: UUID) -> Bool {
        retainedSuspensionClaims[id.uuidString] != nil
            && capacityAdmissionLedger.provisionalReservation.memoryBytes > 0
    }

    func captureRecoveryRecord(_ id: UUID) -> SandboxSuspensionRecord? {
        managedSandboxes[id.uuidString]?.sandboxSuspension
    }
}

/// Records the runtime seam while retaining the normal mock lifecycle. A
/// capture journal deliberately has no checkpoint; checkpoint resume rejects
/// it, whereas original-guest rollback releases its fence before boot succeeds.
private actor CaptureRecoveryRuntime: SandboxRuntimeService {
    let mock = MockSandboxRuntime(logger: Logger(label: "capture-recovery-mock"), bootDelay: .zero)
    var record: SandboxSuspensionRecord
    private(set) var bootCount = 0
    private(set) var resumeCount = 0

    var proofInventory: [String: HostReservation] = [:]
    var proofInventoryUnknown = false
    func setProofInventory(_ proofs: [String: HostReservation], unknown: Bool) {
        proofInventory = proofs
        proofInventoryUnknown = unknown
    }
    func suspensionValidationReservations() throws -> [String: HostReservation] {
        guard !proofInventoryUnknown else { throw SandboxSuspensionGuard.GateError.stale }
        return proofInventory
    }
    var unknownOnSuspensionFailure = false
    func makeInventoryUnknownOnSuspensionFailure() { unknownOnSuspensionFailure = true }
    func suspensionStorageEstimate(sandboxId: String) -> Int64 { 128 * 1024 * 1024 }
    func suspendSandbox(sandboxId: String, generation: Int64, automatic: Bool) throws {
        if unknownOnSuspensionFailure { proofInventoryUnknown = true }
        throw SandboxSuspensionGuard.GateError.stale
    }
    init(record: SandboxSuspensionRecord) { self.record = record }
    func suspensionRecord(sandboxId: String) -> SandboxSuspensionRecord? { record }
    func bootSandbox(sandboxId: String) throws {
        bootCount += 1
        guard record.requiresOriginalGuestRollback else { throw SandboxSuspensionGuard.GateError.stale }
        record.guestFence?.state = .released
    }
    func resumeSuspension(sandboxId: String, networkAttachments: [ResolvedNetworkAttachment]) throws {
        resumeCount += 1
        throw SandboxRuntimeError.notSnapshottable("capture has no committed checkpoint")
    }
    func createSandbox(
        sandboxId: String, spec: SandboxSpec, registryCredential: RegistryCredential?,
        networkAttachments: [ResolvedNetworkAttachment]
    ) async throws {
        try await mock.createSandbox(
            sandboxId: sandboxId, spec: spec, registryCredential: registryCredential,
            networkAttachments: networkAttachments)
    }
    func shutdownSandbox(sandboxId: String) async throws { try await mock.shutdownSandbox(sandboxId: sandboxId) }
    func deleteSandbox(sandboxId: String) async throws { try await mock.deleteSandbox(sandboxId: sandboxId) }
    func adoptSandbox(sandboxId: String, spec: SandboxSpec) async throws -> SandboxStatus {
        try await mock.adoptSandbox(sandboxId: sandboxId, spec: spec)
    }
    // Firecracker may report Running throughout interrupted guest freeze.
    func getSandboxStatus(sandboxId: String) async throws -> SandboxStatus { .running }
    func exitCode(sandboxId: String) async -> Int? { await mock.exitCode(sandboxId: sandboxId) }
    func snapshotSandbox(sandboxId: String, snapshotId: String, mode: SandboxSnapshotMode) async throws
        -> SandboxSnapshotResult
    {
        try await mock.snapshotSandbox(sandboxId: sandboxId, snapshotId: snapshotId, mode: mode)
    }
    func restoreSandbox(
        sandboxId: String, snapshotId: String, artifacts: [SandboxSnapshotArtifactDescriptor]?,
        networkAttachments: [ResolvedNetworkAttachment]
    ) async throws {
        try await mock.restoreSandbox(
            sandboxId: sandboxId, snapshotId: snapshotId, artifacts: artifacts, networkAttachments: networkAttachments)
    }
    func exportSandboxSnapshot(sandboxId: String, snapshotId: String, uploads: [SandboxSnapshotArtifactUploadTarget])
        async throws
    {
        try await mock.exportSandboxSnapshot(sandboxId: sandboxId, snapshotId: snapshotId, uploads: uploads)
    }
    func deleteSandboxSnapshot(sandboxId: String, snapshotId: String) async throws {
        try await mock.deleteSandboxSnapshot(sandboxId: sandboxId, snapshotId: snapshotId)
    }
    func startExec(
        sandboxId: String, sessionId: String, request: SandboxExecRequest,
        events: @escaping @Sendable (SandboxExecEvent) -> Void
    ) async throws {
        try await mock.startExec(sandboxId: sandboxId, sessionId: sessionId, request: request, events: events)
    }
    func sendExecInput(sessionId: String, data: Data?, eof: Bool) async throws {
        try await mock.sendExecInput(sessionId: sessionId, data: data, eof: eof)
    }
    func resizeExec(sessionId: String, rows: Int, cols: Int) async throws {
        try await mock.resizeExec(sessionId: sessionId, rows: rows, cols: cols)
    }
    func closeExec(sessionId: String) async { await mock.closeExec(sessionId: sessionId) }
    func setSandboxLogHandler(_ handler: @escaping @Sendable (String, String, String) -> Void) async {
        await mock.setSandboxLogHandler(handler)
    }
    func controlPlaneDisconnected() async { await mock.controlPlaneDisconnected() }
    func controlPlaneConnected() async { await mock.controlPlaneConnected() }
}
