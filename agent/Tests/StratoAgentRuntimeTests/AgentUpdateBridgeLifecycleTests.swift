import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import StratoShared
import Testing
import WebSocketKit

@testable import StratoAgentCore
@testable import StratoAgentRuntime

@Suite("Registered agent bridge lifecycle", .timeLimit(.minutes(2)))
struct AgentUpdateBridgeLifecycleTests {
    @Test("Transient capability-refresh preflight failure preserves healthy WS and subsequent desired state")
    func transientRefreshKeepsPolling() async throws {
        try await withRegisteredAgent { agent, client, poller, feed, deliveries, _ in
            var iterator = deliveries.makeAsyncIterator()
            feed.yield("before-refresh")
            #expect(await iterator.next() == "before-refresh")
            #expect(await client.isConnected)
            #expect(await poller.isRunning)
            #expect(await agent.assignedAgentID == "registered-bridge-agent")

            await agent.refreshRegistrationAfterNetworkRecovery(fetchBridge: {
                throw URLError(.timedOut)
            })

            #expect(await client.isConnected)
            #expect(await poller.isRunning)
            let stillPolling = await poller.isRunning
            try #require(stillPolling)
            // No reconnect, re-registration response, or manual poller start.
            feed.yield("after-transient-failure")
            #expect(await iterator.next() == "after-transient-failure")
            #expect(await poller.deliveredSyncs == 2)
            try await agent.prepareForWorkloadRegistration(fetchBridge: {
                AgentUpdateBridgeResponse(workloadWireVersion: WireProtocol.currentVersion, update: nil)
            })
            #expect(await poller.isRunning)
        }
    }

    @Test(
        "Verified skew stops workloads, verifies the staged update, and requests supervisor restart",
        arguments: [false, true])
    func skewUpdateLifecycle(validChecksum: Bool) async throws {
        try await withRegisteredAgent { agent, client, poller, feed, deliveries, directory in
            var iterator = deliveries.makeAsyncIterator()
            feed.yield("compatible-baseline")
            #expect(await iterator.next() == "compatible-baseline")
            let binary = directory + "/bridge-agent"
            let artifact = directory + "/staged-artifact"
            try "old binary".write(toFile: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
            try "new binary".write(toFile: artifact, atomically: true, encoding: .utf8)
            let update = DesiredAgentUpdate(
                targetVersion: "bridge-test-target", artifactURL: "https://artifact.test/agent",
                sha256: validChecksum
                    ? try AgentUpdater.sha256Hex(ofFileAt: artifact) : String(repeating: "0", count: 64),
                artifactKind: .binary)
            let updater = AgentUpdater(
                logger: Logger(label: "bridge-updater-test"), installMode: .supervisedBinary,
                binaryPath: binary,
                download: { _, destination in try FileManager.default.copyItem(atPath: artifact, toPath: destination) },
                probe: { _ in })
            await #expect(throws: AgentError.self) {
                try await agent.prepareForWorkloadRegistration(
                    fetchBridge: {
                        AgentUpdateBridgeResponse(workloadWireVersion: WireProtocol.currentVersion + 1, update: update)
                    }, updater: updater)
            }
            #expect(await !poller.isRunning)
            #expect(await agent.updateRestartPending == validChecksum)
            if validChecksum {
                #expect(try String(contentsOfFile: binary, encoding: .utf8) == "new binary")
                #expect(try String(contentsOfFile: binary + ".prev", encoding: .utf8) == "old binary")
                await agent.waitForBridgeTestShutdown()
                #expect(await !client.isConnected)
                #expect(await agent.shutdownRequested)
                #expect(AgentUpdater.restartExitCode == 75)
            } else {
                #expect(try String(contentsOfFile: binary, encoding: .utf8) == "old binary")
                #expect(!FileManager.default.fileExists(atPath: binary + ".prev"))
                #expect(await agent.autoUpdateStatus?.disposition == ObservedAgentUpdateStatus.dispositionFailed)
            }
        }
    }

    private func withRegisteredAgent(
        _ test: (
            Agent, StratoAgentRuntime.WebSocketClient, DesiredStatePoller<ContinuousClock>,
            AsyncStream<String>.Continuation, AsyncStream<String>, String
        ) async throws -> Void
    ) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 20, automaticErrorHandling: true,
            shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { channel, _ in
                WebSocket.server(on: channel) { ws in
                    ws.onText { ws, text in
                        do {
                            let envelope = try WireProtocol.makeDecoder().decode(
                                MessageEnvelope.self, from: Data(text.utf8))
                            guard envelope.type == .agentRegister else { return }
                            let registration = try envelope.decode(as: AgentRegisterMessage.self)
                            let response = AgentRegisterResponseMessage(
                                requestId: registration.requestId, agentId: "registered-bridge-agent",
                                name: "bridge-test")
                            ws.send(String(decoding: try WireProtocol.encodeEnvelope(response), as: UTF8.self))
                        } catch {
                            _ = ws.close(code: .unexpectedServerError)
                        }
                    }
                }
            })
        let listener = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
            }.bind(host: "127.0.0.1", port: 0).get()
        let port = try #require(listener.localAddress?.port)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let logger = Logger(label: "registered-bridge-test")
        let agent = Agent(
            agentID: "bridge-test", webSocketURL: "ws://127.0.0.1:\(port)/agent/ws",
            configuration: runtimeTestConfiguration(
                path: directory, simulation: SimulationConfig(enabled: true),
                installMode: .supervisedBinary), logger: logger)
        let (feed, input) = AsyncStream<String>.makeStream()
        let (deliveries, output) = AsyncStream<String>.makeStream()
        let poller = DesiredStatePoller(
            fetch: { _ in
                var iterator = feed.makeAsyncIterator()
                guard let sync = await iterator.next() else { throw CancellationError() }
                return DesiredStatePollResponse(
                    status: 200, etag: sync,
                    body: try WireProtocol.encodeEnvelope(DesiredStateMessage(syncId: sync, vms: [])))
            },
            deliver: { envelope in
                await agent.routeInboundMessage(envelope)
                if let desired = try? envelope.decode(as: DesiredStateMessage.self) { output.yield(desired.syncId) }
            }, logger: logger)
        let client = await agent.installBridgeTestConnection(port: port, poller: poller)
        do {
            _ = try await client.connect()
            try await agent.registerWithControlPlane()
            try await test(agent, client, poller, input, deliveries, directory)
            input.finish()
            await agent.stop()
            try await listener.close()
            try await group.shutdownGracefully()
        } catch {
            input.finish()
            await agent.stop()
            try? await listener.close()
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

extension Agent {
    fileprivate func installBridgeTestConnection(port: Int, poller: DesiredStatePoller<ContinuousClock>)
        -> StratoAgentRuntime.WebSocketClient
    {
        desiredStatePoller = poller
        let client = StratoAgentRuntime.WebSocketClient(
            url: "ws://127.0.0.1:\(port)/agent/ws", agent: self, logger: logger,
            inboundContinuation: inboundContinuation)
        websocketClient = client
        startMessageConsumer()
        return client
    }

    fileprivate func waitForBridgeTestShutdown() async {
        guard websocketClient != nil else { return }
        await withCheckedContinuation { shutdownContinuation = $0 }
    }
}
