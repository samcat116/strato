import Foundation
import Testing
import Valkey
import Vapor
import AppTestSupport
@testable import App

/// Run against a disposable TCP sink that accepts connections and reads bytes
/// without responding. No production endpoint or firewall changes are needed.
@Suite("Coordination TCP blackhole", .enabled(if: Environment.get("STRATO_BLACKHOLE_PORT") != nil))
struct CoordinationBlackholeTests {
    @Test("Real Valkey client reaches bounded degradation and shares it with authentication")
    func blackholedClient() async throws {
        let port = try #require(Environment.get("STRATO_BLACKHOLE_PORT").flatMap(Int.init))
        let app = try await Application.make(.testing)
        let endpoint = ValkeyConfiguration(hostname: "127.0.0.1", port: port)
        app.configureValkey(.init(coordination: endpoint, session: endpoint, warnings: []))
        let client = app.coordinationValkey
        let run = Task { try await client.run() }
        defer { run.cancel() }
        do {
            let service = CoordinationService(
                store: ValkeyCoordinationStore(app: app), logger: app.logger, deadline: .milliseconds(100))
            let backend = RateLimitBackend(
                fallbackStore: InMemoryRateLimitStore(), valkeyStore: ValkeyRateLimitStore(client: client),
                deadline: .milliseconds(100), gate: service.failureGate)
            for _ in 0..<3 {
                #expect(await service.isAgentPresent(agentKey: "fixture") == nil)
            }
            #expect(await service.failureGate.unavailable)
            let started = ContinuousClock.now
            for _ in 0..<40 {
                #expect(
                    await service.reserveCapacity(
                        agentId: "fixture", vmId: UUID().uuidString,
                        amounts: .zero, capacity: .zero))
            }
            #expect(started.duration(to: .now) < .milliseconds(100))
            #expect(try await backend.hit("fixture", window: 60).count == 1)
            #expect(try await backend.hit("fixture", window: 60).count == 2)
        } catch {
            run.cancel()
            try await app.shutdownForTesting()
            throw error
        }
        run.cancel()
        try await app.shutdownForTesting()
    }
}
