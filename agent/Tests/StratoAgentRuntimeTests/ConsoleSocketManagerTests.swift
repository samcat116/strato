import Foundation
import Logging
import NIOCore
import NIOPosix
import StratoShared
import Synchronization
import Testing

@testable import StratoAgentRuntime

@Suite("Console socket flow control")
struct ConsoleSocketManagerTests {
    private final class ReadRequests: ChannelDuplexHandler, Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundIn = ByteBuffer

        private struct State {
            var count = 0
            var firstCycleScheduled = false
        }
        private let state = Mutex(State())
        let firstCycle = AsyncStream<Int>.makeStream()

        func read(context: ChannelHandlerContext) {
            state.withLock { $0.count += 1 }
            context.read()
        }

        func channelReadComplete(context: ChannelHandlerContext) {
            context.fireChannelReadComplete()
            let schedule = state.withLock { state in
                guard !state.firstCycleScheduled else { return false }
                state.firstCycleScheduled = true
                return true
            }
            if schedule {
                // NIO issues its automatic next read after this callback returns.
                // Observe demand on the same loop after that first read cycle,
                // independently of when the peer's later writes become readable.
                context.eventLoop.execute {
                    self.firstCycle.continuation.yield(self.state.withLock { $0.count })
                    self.firstCycle.continuation.finish()
                }
            }
        }
    }

    private final class ReadSizes: Sendable {
        let values = Mutex<[Int]>([])
    }

    private struct OneByteReads: RecvByteBufferAllocator {
        let sizes: ReadSizes

        func buffer(allocator: ByteBufferAllocator) -> ByteBuffer { allocator.buffer(capacity: 1) }
        func nextBufferSize() -> Int? { 1 }

        mutating func record(actualReadBytes: Int) -> Bool {
            if actualReadBytes > 0 { sizes.values.withLock { $0.append(actualReadBytes) } }
            return false
        }
    }

    private final class InputRecorder: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        let bytes = Mutex(Data())

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            bytes.withLock { $0.append(contentsOf: buffer.readableBytesView) }
        }
    }

    @Test(
        "a slow relay survives small reads and preserves input, output, and EOF",
        .timeLimit(.minutes(1)),
        arguments: [ConsoleStream.serial, .vnc])
    func slowRelaySurvivesSerialBurst(stream: ConsoleStream) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let peers = AsyncStream<Channel>.makeStream()
        let input = InputRecorder()
        let group = MultiThreadedEventLoopGroup.singleton
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(input).map { peers.continuation.yield(channel) }.map { _ in }
            }
            .bind(unixDomainSocketPath: path).get()
        let loop = group.next()
        let readSizes = ReadSizes()
        let readRequests = ReadRequests()
        let manager = ConsoleSocketManager(
            logger: Logger(label: "console-test"), eventLoopGroup: loop,
            initializeChannel: { channel in
                channel.setOption(ChannelOptions.recvAllocator, value: OneByteReads(sizes: readSizes)).flatMap {
                    channel.pipeline.addHandler(readRequests)
                }
            })
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let received = Mutex(Data())
        let closed = Mutex(false)
        await manager.setOnConsoleData { _, _, data in
            entered.continuation.finish()
            for await _ in release.stream {}
            received.withLock { $0.append(data) }
        }
        await manager.setOnConsoleClosed { _, _, _ in closed.withLock { $0 = true } }
        try await manager.connect(vmId: "vm", sessionId: "session", stream: stream, socketPath: path)
        var peerIterator = peers.stream.makeAsyncIterator()
        let peer = try #require(await peerIterator.next())

        let paste = Data("networkctl status enp1s0 --no-pager\r".utf8)
        try await manager.write(sessionId: "session", data: paste)
        // Force one-byte reads at the receiving socket: Unix streams can coalesce
        // writes regardless of how they are paced. Hold the first chunk in the
        // sink, then queue the rest of the burst in a single write.
        let output = Data(String(repeating: "\u{1b}[32m● enp1s0\u{1b}[0m\r\n", count: 100).utf8)
        do {
            try await peer.writeAndFlush(ByteBuffer(bytes: output.prefix(1))).get()
            for await _ in entered.stream {}
            var readCycle = readRequests.firstCycle.stream.makeAsyncIterator()
            let demandWhileHeld = try #require(await readCycle.next())
            #expect(demandWhileHeld == 1)
            try await peer.writeAndFlush(ByteBuffer(bytes: output.dropFirst())).get()
            #expect(!closed.withLock { $0 })
            release.continuation.finish()
            for _ in 0..<500 where received.withLock({ $0.count }) < output.count {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(received.withLock { $0 } == output)
            #expect(readSizes.values.withLock { $0.count } == output.count)
            #expect(readSizes.values.withLock { $0.allSatisfy { $0 == 1 } })
            #expect(input.bytes.withLock { $0 } == paste)
            #expect(!closed.withLock { $0 })
            try await peer.close().get()
            for _ in 0..<500 where !closed.withLock({ $0 }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(closed.withLock { $0 })
            #expect(await manager.getSessionsForVM(vmId: "vm", stream: stream).isEmpty)
        } catch {
            release.continuation.finish()
            await manager.disconnect(sessionId: "session")
            try? await peer.close().get()
            try? await server.close().get()
            throw error
        }
        try await server.close().get()
    }
}
