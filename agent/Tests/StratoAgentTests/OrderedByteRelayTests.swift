import Foundation
import Testing

@testable import StratoAgentCore

/// The console bridge relays a byte stream, and a byte stream that arrives out
/// of order is not slightly wrong — it is unparseable. RFB in particular reads
/// a length-prefixed message header and then exactly that many bytes, so one
/// transposition desynchronizes the client permanently (issue #566).
@Suite("Ordered byte relay")
struct OrderedByteRelayTests {

    /// An actor sink, so the assertions cannot themselves be the thing
    /// serializing the writes.
    private actor Recorder {
        private(set) var chunks: [Int] = []
        private let done: (Int) -> Void

        init(done: @escaping (Int) -> Void) {
            self.done = done
        }

        func record(_ value: Int) async {
            chunks.append(value)
            done(chunks.count)
        }

        func snapshot() -> [Int] { chunks }
    }

    /// The regression this type exists for. The sink suspends on every chunk —
    /// as the real one does, sending a WebSocket frame — which is exactly the
    /// window a task-per-chunk relay reorders in.
    @Test("chunks reach a suspending sink in the order they were sent")
    func chunksArriveInOrder() async throws {
        let count = 500
        let allDelivered = AsyncStream<Void>.makeStream()
        let recorder = Recorder { delivered in
            if delivered == count { allDelivered.continuation.finish() }
        }

        let relay = OrderedByteRelay { data in
            // Suspend before recording, so ordering can only come from the
            // relay and never from the sink happening to be synchronous.
            await Task.yield()
            await recorder.record(Int(data[0]) << 8 | Int(data[1]))
        }

        for index in 0..<count {
            relay.send(Data([UInt8(index >> 8), UInt8(index & 0xff)]))
        }
        relay.finish()

        for await _ in allDelivered.stream {}
        #expect(await recorder.snapshot() == Array(0..<count))
    }

    /// `finish()` is the graceful path: the peer is still there, so bytes
    /// already queued must still be delivered.
    @Test("finishing drains what was already queued")
    func finishDrainsQueuedChunks() async throws {
        let allDelivered = AsyncStream<Void>.makeStream()
        let recorder = Recorder { delivered in
            if delivered == 3 { allDelivered.continuation.finish() }
        }
        let relay = OrderedByteRelay { data in await recorder.record(Int(data[0])) }

        relay.send(Data([1]))
        relay.send(Data([2]))
        relay.send(Data([3]))
        relay.finish()

        for await _ in allDelivered.stream {}
        #expect(await recorder.snapshot() == [1, 2, 3])
    }

    /// Sending after the relay is finished is a no-op rather than a crash: a
    /// channel can deliver a last read while teardown is already in flight.
    @Test("sending after finish is harmless")
    func sendAfterFinishIsIgnored() async throws {
        let recorder = Recorder { _ in }
        let relay = OrderedByteRelay { data in await recorder.record(Int(data[0])) }
        relay.finish()
        relay.send(Data([9]))
        #expect(await recorder.snapshot().isEmpty)
    }
}
