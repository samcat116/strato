#if os(Linux)
import Logging
import NIOCore
import NIOPosix
import Synchronization
import Testing
import StratoAgentCore
import SwiftOVN

@Suite("OVN connection deadlines", .timeLimit(.minutes(1)))
struct OVNConnectionDeadlineTests {
    @Test func deadlineStopsALibraryOwnedReconnect() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let clients = Mutex<[any Channel]>([])
        let listener = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                clients.withLock { $0.append(channel) }
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let port = try #require(listener.localAddress?.port)
        let connection = OVSDBSocketConnection(
            endpoint: .tcp(host: "127.0.0.1", port: port), eventLoopGroup: group,
            logger: Logger(label: "test"))
        do {
            try await connection.connect()
            // Remove a previously reachable peer. SwiftOVN now owns a retry
            // supervisor, and connect() waits on its activation promise.
            try await listener.close().get()
            for client in clients.withLock({ $0 }) { try? await client.close().get() }
            while connection.isConnectionActive { await Task.yield() }
            await #expect(throws: ConnectionDeadline.Exceeded.self) {
                try await ConnectionDeadline.run(
                    timeout: .milliseconds(100), connect: { try await connection.connect() },
                    interrupt: { await connection.disconnect() })
            }
            #expect(!connection.isConnectionActive)
            // A new initial attempt must fail normally against the closed
            // listener, without joining the previous reconnect supervisor.
            await #expect(throws: OVNManagerError.self) {
                try await ConnectionDeadline.run(
                    timeout: .seconds(5), connect: { try await connection.connect() },
                    interrupt: { await connection.disconnect() })
            }
            try await group.shutdownGracefully()
        } catch {
            await connection.disconnect()
            try? await listener.close().get()
            for client in clients.withLock({ $0 }) { try? await client.close().get() }
            try? await group.shutdownGracefully()
            throw error
        }
    }
}
#endif
