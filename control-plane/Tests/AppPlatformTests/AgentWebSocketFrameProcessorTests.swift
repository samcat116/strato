import Foundation
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
        private(set) var frames: [Data] = []

        func append(_ frame: Data) {
            frames.append(frame)
        }
    }

    @Test("The FIFO rejects bytes beyond its fixed limit")
    func bufferIsByteBounded() {
        var buffer = BoundedAgentFrameBuffer(byteLimit: 5)

        let acceptedABC = buffer.append(Data("abc".utf8))
        let acceptedDE = buffer.append(Data("de".utf8))
        let acceptedF = buffer.append(Data("f".utf8))
        #expect(acceptedABC)
        #expect(acceptedDE)
        #expect(!acceptedF)
        #expect(buffer.bufferedBytes == 5)
        #expect(buffer.count == 2)
        let first = buffer.popFirst()
        #expect(first == Data("abc".utf8))
        #expect(buffer.bufferedBytes == 2)
        let acceptedFGH = buffer.append(Data("fgh".utf8))
        let second = buffer.popFirst()
        let third = buffer.popFirst()
        #expect(acceptedFGH)
        #expect(second == Data("de".utf8))
        #expect(third == Data("fgh".utf8))
    }

    @Test("Binary bytes survive the bounded FIFO without UTF-8 conversion")
    func binaryBytesArePreserved() {
        let bytes = Data([0, 0xff, 0xc0, 0x80, 0x0a])
        var buffer = BoundedAgentFrameBuffer(byteLimit: bytes.count)
        let accepted = buffer.append(bytes)
        let overflowAccepted = buffer.append(Data([1]))
        let received = buffer.popFirst()
        #expect(accepted)
        #expect(!overflowAccepted)
        #expect(received == bytes)
        #expect(buffer.bufferedBytes == 0)
    }

    @Test("Revocation discards queued frames and waits only for the active handler")
    func revocationDiscardsQueuedFrames() async {
        let started = Latch()
        let release = Latch()
        let recorder = Recorder()
        let processor = AgentWebSocketFrameProcessor { frame in
            await recorder.append(frame)
            await started.signal()
            await release.wait()
        }
        #expect(processor.enqueue(Data("active".utf8)) == .accepted)
        await started.wait()
        #expect(processor.enqueue(Data("queued".utf8)) == .accepted)
        let active = processor.stopAndDiscard()
        #expect(processor.enqueue(Data("after revocation".utf8)) == .closed)
        await release.signal()
        await active?.value
        await processor.finishAndDrain()
        #expect(await recorder.frames == [Data("active".utf8)])
    }

    @Test("Finish waits for accepted frames in wire order")
    func finishDrainsAcceptedFrames() async {
        let firstStarted = Latch()
        let releaseFirst = Latch()
        let drainFinished = Latch()
        let recorder = Recorder()
        let processor = AgentWebSocketFrameProcessor(bufferLimitBytes: 64) { frame in
            await recorder.append(frame)
            if frame == Data("first".utf8) {
                await firstStarted.signal()
                await releaseFirst.wait()
            }
        }

        #expect(processor.enqueue(Data("first".utf8)) == .accepted)
        #expect(processor.enqueue(Data("second".utf8)) == .accepted)
        await firstStarted.wait()

        let drain = Task {
            await processor.finishAndDrain()
            await drainFinished.signal()
        }
        await Task.yield()
        #expect(!(await drainFinished.isSignaled))

        await releaseFirst.signal()
        await drain.value
        #expect(await recorder.frames == [Data("first".utf8), Data("second".utf8)])
        #expect(processor.enqueue(Data("third".utf8)) == .closed)
    }
}
