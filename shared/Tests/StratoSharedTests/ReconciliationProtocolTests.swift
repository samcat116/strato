import Testing
import Foundation
@testable import StratoShared

@Suite("Reconciliation Protocol Tests")
struct ReconciliationProtocolTests {

    private func makeDesiredState() -> DesiredStateMessage {
        DesiredStateMessage(
            syncId: "sync-1",
            vms: [
                DesiredVMState(
                    vmId: UUID(),
                    hypervisorType: .qemu,
                    spec: VMSpec(cpus: 2, memoryBytes: 2 << 30, boot: .disk(firmware: nil)),
                    desiredStatus: .running,
                    generation: 7,
                    imageInfo: ImageInfo(
                        imageId: UUID(),
                        projectId: UUID(),
                        filename: "debian.qcow2",
                        checksum: "abc",
                        size: 1024,
                        downloadURL: "https://example.test/dl"
                    )
                )
            ]
        )
    }

    @Test("DesiredStateMessage round-trips through the envelope")
    func desiredStateRoundTrip() throws {
        let message = makeDesiredState()
        let envelope = try MessageEnvelope(message: message)
        #expect(envelope.type == .desiredState)
        #expect(envelope.senderVersion == WireProtocol.currentVersion)

        let decoded = try envelope.decode(as: DesiredStateMessage.self)
        #expect(decoded.syncId == message.syncId)
        #expect(decoded.vms.count == 1)
        #expect(decoded.vms[0].vmId == message.vms[0].vmId)
        #expect(decoded.vms[0].desiredStatus == .running)
        #expect(decoded.vms[0].generation == 7)
        #expect(decoded.vms[0].imageInfo?.filename == "debian.qcow2")
    }

    @Test("DesiredStateMessage carries networks through the envelope")
    func desiredStateNetworksRoundTrip() throws {
        let networkId = UUID()
        let projectKey = "project-\(UUID().uuidString)"
        let message = DesiredStateMessage(
            syncId: "sync-net",
            vms: [],
            networks: [
                DesiredNetworkState(
                    networkId: networkId,
                    name: "default",
                    subnet: "192.168.1.0/24",
                    gateway: "192.168.1.1",
                    routerKey: projectKey,
                    externalAccess: true,
                    generation: 4
                ),
                DesiredNetworkState(
                    networkId: UUID(),
                    name: "isolated",
                    subnet: "10.0.5.0/24",
                    gateway: nil,
                    routerKey: projectKey,
                    externalAccess: false,
                    generation: 1
                ),
            ]
        )
        let envelope = try MessageEnvelope(message: message)
        let decoded = try envelope.decode(as: DesiredStateMessage.self)

        #expect(decoded.networks.count == 2)
        #expect(decoded.networks[0].networkId == networkId)
        #expect(decoded.networks[0].subnet == "192.168.1.0/24")
        #expect(decoded.networks[0].gateway == "192.168.1.1")
        #expect(decoded.networks[0].routerKey == projectKey)
        #expect(decoded.networks[0].externalAccess)
        #expect(decoded.networks[0].generation == 4)
        // Same router key: both networks share one per-project logical router.
        #expect(decoded.networks[1].routerKey == projectKey)
        #expect(decoded.networks[1].gateway == nil)
        #expect(!decoded.networks[1].externalAccess)
    }

    @Test("DesiredStateMessage from an older control plane decodes networks to []")
    func desiredStateNetworksBackwardCompatible() throws {
        // A pre-v3 control plane emits no `networks` key at all; the agent must
        // tolerate its absence rather than fail the whole sync.
        let legacy = """
            {"requestId":"r","timestamp":0,"syncId":"s","vms":[]}
            """
        let decoded = try WireProtocol.makeDecoder().decode(
            DesiredStateMessage.self, from: Data(legacy.utf8))
        #expect(decoded.networks.isEmpty)
        #expect(decoded.syncId == "s")
    }

    @Test("ObservedStateReport round-trips through the envelope")
    func observedStateRoundTrip() throws {
        let message = ObservedStateReport(
            agentId: "agent-1",
            vms: [
                ObservedVMState(
                    vmId: UUID(),
                    status: .running,
                    observedGeneration: 7,
                    convergencePhase: nil,
                    lastError: nil
                ),
                ObservedVMState(
                    vmId: UUID(),
                    status: .unknown,
                    observedGeneration: 0,
                    convergencePhase: "downloading image",
                    lastError: "previous attempt: disk full",
                    failedGeneration: 3
                ),
            ],
            resources: AgentResources(
                totalCPU: 8, availableCPU: 4,
                totalMemory: 16, availableMemory: 8,
                totalDisk: 100, availableDisk: 50
            )
        )
        let envelope = try MessageEnvelope(message: message)
        #expect(envelope.type == .observedState)

        let decoded = try envelope.decode(as: ObservedStateReport.self)
        #expect(decoded.agentId == "agent-1")
        #expect(decoded.vms.count == 2)
        #expect(decoded.vms[0].observedGeneration == 7)
        #expect(decoded.vms[1].convergencePhase == "downloading image")
        #expect(decoded.vms[1].lastError == "previous attempt: disk full")
        #expect(decoded.vms[1].failedGeneration == 3)
    }

    @Test("DesiredVMStatus decoding is strict: unknown values fail the sync")
    func desiredStatusStrictDecoding() throws {
        let decoder = WireProtocol.makeDecoder()
        // Misinterpreting a desired status could stop or delete a running VM,
        // so — unlike VMStatus — there is deliberately no tolerant fallback.
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(DesiredVMStatus.self, from: Data("\"Hibernated\"".utf8))
        }
    }

    @Test("Desired status satisfaction mapping")
    func desiredStatusSatisfaction() {
        #expect(DesiredVMStatus.running.isSatisfied(by: .running))
        #expect(!DesiredVMStatus.running.isSatisfied(by: .paused))
        #expect(DesiredVMStatus.paused.isSatisfied(by: .paused))
        // A defined-but-never-booted VM satisfies "shutdown" — same resting state.
        #expect(DesiredVMStatus.shutdown.isSatisfied(by: .created))
        #expect(DesiredVMStatus.shutdown.isSatisfied(by: .shutdown))
        #expect(!DesiredVMStatus.shutdown.isSatisfied(by: .running))
        // Absence is confirmed by omission from the observed set, never by a status.
        for status in VMStatus.allCases {
            #expect(!DesiredVMStatus.absent.isSatisfied(by: status))
        }
    }

    @Test("State-sync support is keyed on protocol version 2")
    func stateSyncVersionGate() {
        #expect(!WireProtocol.supportsStateSync(0))
        #expect(!WireProtocol.supportsStateSync(1))
        #expect(WireProtocol.supportsStateSync(2))
        #expect(WireProtocol.supportsStateSync(3))
        #expect(WireProtocol.supportsStateSync(WireProtocol.currentVersion))
    }
}
