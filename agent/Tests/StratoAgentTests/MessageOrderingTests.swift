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

    @Test("VM id lane is case-insensitive to UUID formatting")
    func vmIdNormalizedAcrossCasing() {
        let vmId = UUID()
        let upper = MessageEnvelope.serializationKeys(
            type: .vmReboot, payload: payload(["vmId": vmId.uuidString])
        )
        let lower = MessageEnvelope.serializationKeys(
            type: .vmReboot, payload: payload(["vmId": vmId.uuidString.lowercased()])
        )
        #expect(upper == lower)
    }

    @Test("Different VMs get different lanes")
    func differentVMsGetDifferentLanes() {
        let a = MessageEnvelope.serializationKeys(
            type: .vmReboot, payload: payload(["vmId": UUID().uuidString])
        )
        let b = MessageEnvelope.serializationKeys(
            type: .vmReboot, payload: payload(["vmId": UUID().uuidString])
        )
        #expect(a != b)
    }

    /// The one volume verb that is still imperative (ADR 0001 stage 7) takes
    /// the *reconciler's* volume lane, not a bare-id one — so the read can
    /// never run concurrently with the reconciler resizing or deleting the
    /// same volume (STR-148, STR-150).
    @Test("The surviving volume frame shares the reconciler's volume lane")
    func volumeFramesUseReconcilerLane() {
        let volumeId = UUID().uuidString
        let expected = ["volume/" + volumeId]

        let infoKeys = MessageEnvelope.serializationKeys(
            type: .volumeInfo, payload: payload(["volumeId": volumeId, "volumePath": "/a"])
        )

        #expect(infoKeys == expected)
    }

    /// The lane string is built from the *canonical* uuid, because the
    /// reconciler's `laneKeys` are and a prefix defeats the normalization that
    /// happens after the switch.
    @Test("Volume lanes normalize uuid casing before prefixing")
    func volumeLaneNormalizesCasing() {
        let volumeId = UUID()
        let lower = MessageEnvelope.serializationKeys(
            type: .volumeInfo,
            payload: payload(["volumeId": volumeId.uuidString.lowercased(), "volumePath": "/a"])
        )
        let upper = MessageEnvelope.serializationKeys(
            type: .volumeInfo,
            payload: payload(["volumeId": volumeId.uuidString, "volumePath": "/a"])
        )
        #expect(lower == upper)
        #expect(lower == ["volume/" + volumeId.uuidString])
    }

    // The network-frame lanes are gone with the imperative network path itself
    // (issue #765): topology is level-triggered from the desired-state sync,
    // which rides `reconcileLane`.

    @Test("Sandbox exec frames for one session share a per-session lane")
    func sandboxExecFramesShareSessionLane() {
        let sandboxId = UUID().uuidString
        let sessionId = UUID().uuidString
        let startKeys = MessageEnvelope.serializationKeys(
            type: .sandboxExecStart,
            payload: payload(["sandboxId": sandboxId, "sessionId": sessionId, "command": ["/bin/sh"]])
        )
        let inputKeys = MessageEnvelope.serializationKeys(
            type: .sandboxExecInput, payload: payload(["sessionId": sessionId, "eof": false])
        )
        let resizeKeys = MessageEnvelope.serializationKeys(
            type: .sandboxExecResize, payload: payload(["sessionId": sessionId, "rows": 24, "cols": 80])
        )
        let closeKeys = MessageEnvelope.serializationKeys(
            type: .sandboxExecClose, payload: payload(["sessionId": sessionId])
        )

        // Input/resize/close are applied strictly after the session's start...
        #expect(startKeys == ["exec:\(sessionId)"])
        #expect(inputKeys == startKeys)
        #expect(resizeKeys == startKeys)
        #expect(closeKeys == startKeys)
        // ...while staying off the sandbox's own lifecycle lane and the unkeyed lane.
        #expect(!startKeys.contains(sandboxId))
        #expect(!startKeys.contains(MessageEnvelope.unkeyedSerializationLane))
    }

    @Test("Sandbox exec sessions get independent lanes")
    func sandboxExecSessionsAreIndependent() {
        let a = MessageEnvelope.serializationKeys(
            type: .sandboxExecInput, payload: payload(["sessionId": UUID().uuidString])
        )
        let b = MessageEnvelope.serializationKeys(
            type: .sandboxExecInput, payload: payload(["sessionId": UUID().uuidString])
        )
        #expect(a != b)
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
        let envelope = try MessageEnvelope(message: VMOperationMessage(type: .vmReboot, vmId: vmId))
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
