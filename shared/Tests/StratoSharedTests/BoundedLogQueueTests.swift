import Foundation
import StratoShared
import Testing

@Suite("Bounded workload log queue")
struct BoundedLogQueueTests {
    @Test("Byte pressure sheds oldest lines and oversized lines do not evict good data")
    func bytePressure() {
        let queue = BoundedLogQueue<String>(byteLimit: 300, countLimit: 10)
        queue.append("first", byteCount: 20)
        queue.append("second", byteCount: 20)
        #expect(queue.snapshot.bytes == 296)
        queue.append("third", byteCount: 20)
        #expect(queue.snapshot.dropped == 1)
        #expect(!queue.append("oversize", byteCount: 301))
        #expect(queue.snapshot.dropped == 2)
        #expect(queue.drain() == ["second", "third"])
        #expect(queue.snapshot.bytes == 0)
    }

    @Test("Tiny lines are count bounded and the ring wraps in FIFO order")
    func countPressure() {
        let queue = BoundedLogQueue<Int>(byteLimit: 4096, countLimit: 3)
        for index in 0..<100_000 { queue.append(index, byteCount: 0) }
        #expect(queue.snapshot.count == 3)
        #expect(queue.snapshot.bytes == 384)
        #expect(queue.snapshot.dropped == 99_997)
        #expect(queue.drain(maxCount: 2) == [99_997, 99_998])
        queue.append(100_000, byteCount: 0)
        #expect(queue.drain() == [99_999, 100_000])
    }

    @Test("Concurrent producers stay bounded while the consumer is stalled")
    func concurrentFlood() async {
        let queue = BoundedLogQueue<Int>(byteLimit: 8192, countLimit: 16)
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<8 {
                group.addTask {
                    for line in 0..<10_000 { queue.append(producer * 10_000 + line, byteCount: 1024) }
                }
            }
        }
        #expect(queue.snapshot.count == 7)
        #expect(queue.snapshot.bytes <= queue.byteLimit)
        #expect(queue.snapshot.dropped == 80_000 - 7)
        queue.finish()
        #expect(queue.snapshot.count == 0)
        #expect(queue.snapshot.bytes == 0)
        #expect(queue.snapshot.dropped == 80_000)
        #expect(!queue.append(0, byteCount: 1))
    }

    @Test("Coalesced wakeups keep a slow serial consumer draining every retained line")
    func notifications() async {
        let queue = BoundedLogQueue<Int>(byteLimit: 8192)
        for line in 0..<20 { queue.append(line, byteCount: 10) }
        var values: [Int] = []
        for await _ in queue.notifications {
            values += queue.drain(maxCount: 1)
            if values.count == 20 { queue.finish() }
        }
        #expect(values == Array(0..<20))
    }

    @Test("Active batches obey their byte limit and finish wakes an idle consumer")
    func batchLimit() async {
        let queue = BoundedLogQueue<Int>(byteLimit: 1024)
        queue.append(1, byteCount: 200)
        queue.append(2, byteCount: 200)
        #expect(queue.drain(maxBytes: 400) == [1])
        #expect(queue.drain(maxBytes: 400) == [2])
        queue.finish()
        var iterator = queue.notifications.makeAsyncIterator()
        _ = await iterator.next()  // at most one retained wakeup
        #expect(await iterator.next() == nil)
    }
}
