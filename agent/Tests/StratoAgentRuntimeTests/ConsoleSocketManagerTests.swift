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
        let manager = ConsoleSocketManager(logger: Logger(label: "console-test"), eventLoopGroup: group)
        let release = AsyncStream<Void>.makeStream()
        let received = Mutex(Data())
        let closed = Mutex(false)
        await manager.setOnConsoleData { _, _, data in
            for await _ in release.stream {}
            received.withLock { $0.append(data) }
        }
        await manager.setOnConsoleClosed { _, _, _ in closed.withLock { $0 = true } }
        try await manager.connect(vmId: "vm", sessionId: "session", stream: stream, socketPath: path)
        var peerIterator = peers.stream.makeAsyncIterator()
        let peer = try #require(await peerIterator.next())

        let paste = Data("networkctl status enp1s0 --no-pager\r".utf8)
        try await manager.write(sessionId: "session", data: paste)
        // QEMU serial output can arrive one byte at a time. Hold the control-plane
        // sink while sending more than the relay's 1024-chunk budget, but only 2 KiB.
        let output = Data(String(repeating: "\u{1b}[32m● enp1s0\u{1b}[0m\r\n", count: 100).utf8)
        do {
            for byte in output {
                try await peer.writeAndFlush(ByteBuffer(bytes: [byte])).get()
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(!closed.withLock { $0 })
            release.continuation.finish()
            for _ in 0..<500 where received.withLock({ $0.count }) < output.count {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(received.withLock { $0 } == output)
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
