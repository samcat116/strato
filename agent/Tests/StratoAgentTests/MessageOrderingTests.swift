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
                let backwards = UInt64(count - index) * 1_000_000 // ms, descending
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
        let createKey = MessageEnvelope.serializationKey(
            type: .vmCreate,
            payload: payload(["vmData": ["id": vmId.uuidString], "requestId": "r1"])
        )
        let bootKey = MessageEnvelope.serializationKey(
            type: .vmBoot,
            payload: payload(["vmId": vmId.uuidString, "requestId": "r2"])
        )
        let deleteKey = MessageEnvelope.serializationKey(
            type: .vmDelete,
            payload: payload(["vmId": vmId.uuidString, "requestId": "r3"])
        )

        #expect(createKey == bootKey)
        #expect(bootKey == deleteKey)
    }

    @Test("VM id lane is case-insensitive to UUID formatting")
    func vmIdNormalizedAcrossCasing() {
        let vmId = UUID()
        let upper = MessageEnvelope.serializationKey(
            type: .vmBoot, payload: payload(["vmId": vmId.uuidString])
        )
        let lower = MessageEnvelope.serializationKey(
            type: .vmDelete, payload: payload(["vmId": vmId.uuidString.lowercased()])
        )
        #expect(upper == lower)
    }

    @Test("Different VMs get different lanes")
    func differentVMsGetDifferentLanes() {
        let a = MessageEnvelope.serializationKey(
            type: .vmBoot, payload: payload(["vmId": UUID().uuidString])
        )
        let b = MessageEnvelope.serializationKey(
            type: .vmBoot, payload: payload(["vmId": UUID().uuidString])
        )
        #expect(a != b)
    }

    @Test("Volume operations are keyed by volume id")
    func volumeOperationsKeyedByVolumeId() {
        let volumeId = UUID().uuidString
        let attachKey = MessageEnvelope.serializationKey(
            type: .volumeAttach,
            payload: payload(["vmId": UUID().uuidString, "volumeId": volumeId])
        )
        let detachKey = MessageEnvelope.serializationKey(
            type: .volumeDetach,
            payload: payload(["vmId": UUID().uuidString, "volumeId": volumeId])
        )
        // Same volume attached to then detached from different VMs still shares a lane.
        #expect(attachKey == detachKey)
    }

    @Test("Network operations are keyed by name and never collide with ids")
    func networkOperationsKeyedByName() {
        let createKey = MessageEnvelope.serializationKey(
            type: .networkCreate, payload: payload(["networkName": "net0"])
        )
        let deleteKey = MessageEnvelope.serializationKey(
            type: .networkDelete, payload: payload(["networkName": "net0"])
        )
        #expect(createKey == deleteKey)
        #expect(createKey.hasPrefix("network:"))
    }

    @Test("Frames without a resource id fall back to the shared unkeyed lane")
    func unkeyedFramesShareLane() {
        let successKey = MessageEnvelope.serializationKey(
            type: .success, payload: payload(["requestId": "r1"])
        )
        let listKey = MessageEnvelope.serializationKey(
            type: .networkList, payload: payload(["requestId": "r2"])
        )
        #expect(successKey == MessageEnvelope.unkeyedSerializationLane)
        #expect(listKey == MessageEnvelope.unkeyedSerializationLane)
    }

    @Test("Public serializationKey works end-to-end on a real encoded envelope")
    func publicKeyOnEncodedEnvelope() throws {
        let vmId = UUID().uuidString
        let envelope = try MessageEnvelope(message: VMOperationMessage(type: .vmBoot, vmId: vmId))
        #expect(envelope.serializationKey == vmId)
    }
}
