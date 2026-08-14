import Testing

@testable import App

@Suite("Agent WebSocket frame processor")
struct AgentWebSocketFrameProcessorTests {
    private actor Latch {
        private var signaled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var isSignaled: Bool { signaled }

        func signal() {
            signaled = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func wait() async {
            if signaled { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private actor Recorder {
        private(set) var frames: [String] = []

        func append(_ frame: String) {
            frames.append(frame)
        }
    }

    @Test("The FIFO rejects bytes beyond its fixed limit")
    func bufferIsByteBounded() {
        var buffer = BoundedAgentFrameBuffer(byteLimit: 5)

        let acceptedABC = buffer.append("abc")
        let acceptedDE = buffer.append("de")
        let acceptedF = buffer.append("f")
        #expect(acceptedABC)
        #expect(acceptedDE)
        #expect(!acceptedF)
        #expect(buffer.bufferedBytes == 5)
        #expect(buffer.count == 2)
        let first = buffer.popFirst()
        #expect(first == "abc")
        #expect(buffer.bufferedBytes == 2)
        let acceptedFGH = buffer.append("fgh")
        let second = buffer.popFirst()
        let third = buffer.popFirst()
        #expect(acceptedFGH)
        #expect(second == "de")
        #expect(third == "fgh")
    }

    @Test("Finish waits for accepted frames in wire order")
    func finishDrainsAcceptedFrames() async {
        let firstStarted = Latch()
        let releaseFirst = Latch()
        let drainFinished = Latch()
        let recorder = Recorder()
        let processor = AgentWebSocketFrameProcessor(bufferLimitBytes: 64) { frame in
            await recorder.append(frame)
            if frame == "first" {
                await firstStarted.signal()
                await releaseFirst.wait()
            }
        }

        #expect(processor.enqueue("first") == .accepted)
        #expect(processor.enqueue("second") == .accepted)
        await firstStarted.wait()

        let drain = Task {
            await processor.finishAndDrain()
            await drainFinished.signal()
        }
        await Task.yield()
        #expect(!(await drainFinished.isSignaled))

        await releaseFirst.signal()
        await drain.value
        #expect(await recorder.frames == ["first", "second"])
        #expect(processor.enqueue("third") == .closed)
    }
}
