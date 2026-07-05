import Testing
import Foundation
@testable import StratoAgentCore
import StratoShared

@Suite("Message Ordering Tests")
struct MessageOrderingTests {

    // MARK: - Helpers

    /// Collects appended values and lets a test await until a target count is reached.
    private actor Recorder {
        private(set) var values: [Int] = []

        func append(_ value: Int) { values.append(value) }

        /// Wait until at least `count` values have been recorded, or the timeout elapses.
        func waitForCount(_ count: Int, timeoutMillis: Int = 5000) async -> [Int] {
            var waited = 0
            while values.count < count && waited < timeoutMillis {
                try? await Task.sleep(nanoseconds: 5_000_000)
                waited += 5
            }
            return values
        }
    }

    /// A one-shot signal that suspends `wait()` callers until `fire()` is called.
    private actor Signal {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var fired = false

        func wait() async {
            if fired { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func fire() {
            fired = true
            let pending = continuations
            continuations = []
            for continuation in pending { continuation.resume() }
        }
    }

    private func payload(_ object: [String: Any]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - SerialTaskQueue

    @Test("Same key runs strictly in submission order despite adversarial delays")
    func sameKeyPreservesFIFO() async {
        let queue = SerialTaskQueue()
        let recorder = Recorder()
        let count = 20

        // Earlier items sleep longer than later ones: a non-FIFO executor would surface
        // them out of order. A per-key serial lane must still record 0,1,2,...
        for index in 0..<count {
            await queue.enqueue(key: "vm-A") {
                let backwards = UInt64(count - index) * 1_000_000  // ms, descending
                try? await Task.sleep(nanoseconds: backwards)
                await recorder.append(index)
            }
        }

        let values = await recorder.waitForCount(count)
        #expect(values == Array(0..<count))
    }

    @Test("Different keys make progress concurrently (no head-of-line blocking)")
    func differentKeysRunConcurrently() async {
        let queue = SerialTaskQueue()
        let recorder = Recorder()
        let signal = Signal()

        // Key A blocks until key B releases it. If the two keys shared a single serial lane,
        // A (enqueued first) would deadlock waiting for B, which could never start.
        await queue.enqueue(key: "vm-A") {
            await signal.wait()
            await recorder.append(1)
        }
        await queue.enqueue(key: "vm-B") {
            await signal.fire()
            await recorder.append(2)
        }

        let values = await recorder.waitForCount(2)
        #expect(Set(values) == Set([1, 2]))
    }

    @Test("Independent keys are isolated: one key's ordering is unaffected by another's")
    func interleavedKeysEachPreserveOrder() async {
        let queue = SerialTaskQueue()
        let recorderA = Recorder()
        let recorderB = Recorder()
        let count = 15

        for index in 0..<count {
            await queue.enqueue(key: "vm-A") {
                try? await Task.sleep(nanoseconds: UInt64(count - index) * 500_000)
                await recorderA.append(index)
            }
            await queue.enqueue(key: "vm-B") {
                try? await Task.sleep(nanoseconds: UInt64(index) * 500_000)
                await recorderB.append(index)
            }
        }

        let valuesA = await recorderA.waitForCount(count)
        let valuesB = await recorderB.waitForCount(count)
        #expect(valuesA == Array(0..<count))
        #expect(valuesB == Array(0..<count))
    }

    // MARK: - serializationKey routing

    @Test("Create and subsequent operations for the same VM share a lane")
    func createAndOperationShareLane() {
        let vmId = UUID()
        let createKeys = MessageEnvelope.serializationKeys(
            type: .vmCreate,
            payload: payload(["vmData": ["id": vmId.uuidString], "requestId": "r1"])
        )
        let bootKeys = MessageEnvelope.serializationKeys(
            type: .vmBoot,
            payload: payload(["vmId": vmId.uuidString, "requestId": "r2"])
        )
        let deleteKeys = MessageEnvelope.serializationKeys(
            type: .vmDelete,
            payload: payload(["vmId": vmId.uuidString, "requestId": "r3"])
        )

        #expect(createKeys == bootKeys)
        #expect(bootKeys == deleteKeys)
    }

    @Test("VM creation serializes against its configured network lanes")
    func vmCreateSpansConfiguredNetworkLanes() {
        let vmId = UUID()
        let createKeys = MessageEnvelope.serializationKeys(
            type: .vmCreate,
            payload: payload([
                "vmData": ["id": vmId.uuidString],
                "vmSpec": ["networks": [["network": "net0"], [String: String]()]],
                "requestId": "r1",
            ])
        )
        // The VM lane, the named network, and network:default for the unnamed entry.
        #expect(Set(createKeys) == Set([vmId.uuidString, "network:net0", "network:default"]))

        // Must serialize against an adjacent create/delete of that same network.
        let netDeleteKeys = MessageEnvelope.serializationKeys(
            type: .networkDelete, payload: payload(["networkName": "net0"])
        )
        #expect(!Set(createKeys).isDisjoint(with: netDeleteKeys))
    }

    @Test("VM creation without configured networks uses only the VM lane")
    func vmCreateWithoutNetworksUsesVMLane() {
        let vmId = UUID()
        let createKeys = MessageEnvelope.serializationKeys(
            type: .vmCreate, payload: payload(["vmData": ["id": vmId.uuidString]])
        )
        #expect(createKeys == [vmId.uuidString])
    }

    @Test("VM id lane is case-insensitive to UUID formatting")
    func vmIdNormalizedAcrossCasing() {
        let vmId = UUID()
        let upper = MessageEnvelope.serializationKeys(
            type: .vmBoot, payload: payload(["vmId": vmId.uuidString])
        )
        let lower = MessageEnvelope.serializationKeys(
            type: .vmDelete, payload: payload(["vmId": vmId.uuidString.lowercased()])
        )
        #expect(upper == lower)
    }

    @Test("Different VMs get different lanes")
    func differentVMsGetDifferentLanes() {
        let a = MessageEnvelope.serializationKeys(
            type: .vmBoot, payload: payload(["vmId": UUID().uuidString])
        )
        let b = MessageEnvelope.serializationKeys(
            type: .vmBoot, payload: payload(["vmId": UUID().uuidString])
        )
        #expect(a != b)
    }

    @Test("Volume lifecycle operations are keyed by volume id")
    func volumeOperationsKeyedByVolumeId() {
        let volumeId = UUID().uuidString
        let createKeys = MessageEnvelope.serializationKeys(
            type: .volumeCreate, payload: payload(["volumeId": volumeId])
        )
        let deleteKeys = MessageEnvelope.serializationKeys(
            type: .volumeDelete, payload: payload(["volumeId": volumeId])
        )
        let resizeKeys = MessageEnvelope.serializationKeys(
            type: .volumeResize, payload: payload(["volumeId": volumeId])
        )
        #expect(createKeys == [volumeId])
        #expect(deleteKeys == [volumeId])
        #expect(resizeKeys == [volumeId])
    }

    @Test("Attach then detach of the same volume share the volume lane")
    func attachDetachShareVolumeLane() {
        let volumeId = UUID().uuidString
        let attachKeys = MessageEnvelope.serializationKeys(
            type: .volumeAttach,
            payload: payload(["vmId": UUID().uuidString, "volumeId": volumeId])
        )
        let detachKeys = MessageEnvelope.serializationKeys(
            type: .volumeDetach,
            payload: payload(["vmId": UUID().uuidString, "volumeId": volumeId])
        )
        // Even attached to / detached from different VMs, they still serialize on the volume.
        #expect(!Set(attachKeys).isDisjoint(with: detachKeys))
        #expect(attachKeys.contains(volumeId))
    }

    @Test("Volume attach/detach also serialize against the target VM's lane")
    func volumeHotPlugSpansVMLane() {
        let vmId = UUID().uuidString
        let volumeId = UUID().uuidString
        let attachKeys = MessageEnvelope.serializationKeys(
            type: .volumeAttach,
            payload: payload(["vmId": vmId, "volumeId": volumeId])
        )
        // Hot-plugging must serialize against a delete/shutdown of the same VM.
        let vmDeleteKeys = MessageEnvelope.serializationKeys(
            type: .vmDelete, payload: payload(["vmId": vmId])
        )
        #expect(Set(attachKeys) == Set([vmId, volumeId]))
        #expect(!Set(attachKeys).isDisjoint(with: vmDeleteKeys))
    }

    @Test("Network attach serializes against both the VM and the named network")
    func networkAttachSpansVMAndNetworkLanes() {
        let vmId = UUID().uuidString
        let attachKeys = MessageEnvelope.serializationKeys(
            type: .networkAttach,
            payload: payload(["vmId": vmId, "networkName": "net0"])
        )
        // Must serialize against an adjacent create/delete of the same network...
        let netCreateKeys = MessageEnvelope.serializationKeys(
            type: .networkCreate, payload: payload(["networkName": "net0"])
        )
        // ...and against lifecycle of the same VM.
        let vmDeleteKeys = MessageEnvelope.serializationKeys(
            type: .vmDelete, payload: payload(["vmId": vmId])
        )
        #expect(Set(attachKeys) == Set([vmId, "network:net0"]))
        #expect(!Set(attachKeys).isDisjoint(with: netCreateKeys))
        #expect(!Set(attachKeys).isDisjoint(with: vmDeleteKeys))
    }

    @Test("Volume clone serializes against both its source and target volume lanes")
    func volumeCloneSpansBothVolumeLanes() {
        let sourceId = UUID().uuidString
        let targetId = UUID().uuidString
        let cloneKeys = MessageEnvelope.serializationKeys(
            type: .volumeClone,
            payload: payload([
                "sourceVolumeId": sourceId, "sourceVolumePath": "/a",
                "targetVolumeId": targetId, "targetVolumePath": "/b",
            ])
        )

        // The clone participates in both volumes' lanes, so a resize of the source or a
        // delete of the target cannot slip past it.
        let sourceResizeKeys = MessageEnvelope.serializationKeys(
            type: .volumeResize, payload: payload(["volumeId": sourceId])
        )
        let targetDeleteKeys = MessageEnvelope.serializationKeys(
            type: .volumeDelete, payload: payload(["volumeId": targetId])
        )

        #expect(Set(cloneKeys) == Set([sourceId, targetId]))
        #expect(!Set(cloneKeys).isDisjoint(with: sourceResizeKeys))
        #expect(!Set(cloneKeys).isDisjoint(with: targetDeleteKeys))
        #expect(!cloneKeys.contains(MessageEnvelope.unkeyedSerializationLane))
    }

    @Test("Named network create/delete share the per-name lane and the visibility lane")
    func networkMutationsKeyedByNameAndVisibility() {
        let createKeys = MessageEnvelope.serializationKeys(
            type: .networkCreate, payload: payload(["networkName": "net0"])
        )
        let deleteKeys = MessageEnvelope.serializationKeys(
            type: .networkDelete, payload: payload(["networkName": "net0"])
        )
        #expect(Set(createKeys) == Set(deleteKeys))
        #expect(createKeys.contains("network:net0"))
        #expect(createKeys.contains(MessageEnvelope.networkVisibilityLane))
    }

    @Test("Network list shares the visibility lane with create/delete so it can't read stale state")
    func networkListSharesVisibilityLane() {
        let listKeys = MessageEnvelope.serializationKeys(
            type: .networkList, payload: payload(["requestId": "r1"])
        )
        let createKeys = MessageEnvelope.serializationKeys(
            type: .networkCreate, payload: payload(["networkName": "net0"])
        )
        let deleteKeys = MessageEnvelope.serializationKeys(
            type: .networkDelete, payload: payload(["networkName": "net9"])
        )
        #expect(listKeys == [MessageEnvelope.networkVisibilityLane])
        // A list serializes after a create/delete of *any* network via the shared lane.
        #expect(!Set(listKeys).isDisjoint(with: createKeys))
        #expect(!Set(listKeys).isDisjoint(with: deleteKeys))
    }

    @Test("Frames without a resource id fall back to the shared unkeyed lane")
    func unkeyedFramesShareLane() {
        let successKeys = MessageEnvelope.serializationKeys(
            type: .success, payload: payload(["requestId": "r1"])
        )
        let errorKeys = MessageEnvelope.serializationKeys(
            type: .error, payload: payload(["requestId": "r2"])
        )
        #expect(successKeys == [MessageEnvelope.unkeyedSerializationLane])
        #expect(errorKeys == [MessageEnvelope.unkeyedSerializationLane])
    }

    @Test("Public serializationKeys works end-to-end on a real encoded envelope")
    func publicKeyOnEncodedEnvelope() throws {
        let vmId = UUID().uuidString
        let envelope = try MessageEnvelope(message: VMOperationMessage(type: .vmBoot, vmId: vmId))
        #expect(envelope.serializationKeys == [vmId])
    }

    @Test("A multi-lane item serializes against work on each of its lanes")
    func multiLaneItemSerializesAcrossLanes() async {
        let queue = SerialTaskQueue()
        let recorder = Recorder()

        // Prior work on lane A, then a clone spanning {A, B}, then work on lane B. FIFO on
        // each shared lane must yield: A-op (0) before clone (1), and clone (1) before B-op (2).
        await queue.enqueue(key: "vol-A") {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await recorder.append(0)
        }
        await queue.enqueue(keys: ["vol-A", "vol-B"]) {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await recorder.append(1)
        }
        await queue.enqueue(key: "vol-B") {
            await recorder.append(2)
        }

        let values = await recorder.waitForCount(3)
        #expect(values == [0, 1, 2])
    }
}
