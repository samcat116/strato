import Foundation
import NIOConcurrencyHelpers
import Testing
import Vapor
import StratoShared
@testable import App

@Suite("Loki HTTP delivery", .serialized)
struct LokiPushTests {
    private func withOrigin(
        status: HTTPResponseStatus = .noContent, delay: Duration = .zero, bodyBytes: Int = 0,
        bodyDelay: Duration = .zero,
        test: (LokiService, NIOLockedValueBox<Int>) async throws -> Void
    ) async throws {
        var environment = Environment.testing
        environment.arguments = ["vapor"]
        let origin = try await Application.make(environment)
        let app = try await Application.make(environment)
        let requests = NIOLockedValueBox(0)
        origin.post("loki", "api", "v1", "push") { request async throws -> Response in
            requests.withLockedValue { $0 += 1 }
            #expect(request.headers.first(name: "Content-Type") == "application/json")
            try await Task.sleep(for: delay)
            if bodyDelay > .zero {
                return Response(
                    status: status,
                    body: .init(managedAsyncStream: { writer in
                        try await writer.write(.buffer(ByteBuffer(string: "prefix")))
                        try await Task.sleep(for: bodyDelay)
                    }))
            }
            return Response(status: status, body: .init(string: String(repeating: "x", count: bodyBytes)))
        }
        func teardown() async {
            await origin.server.shutdown()
            try? await origin.asyncShutdown()
            try? await app.asyncShutdown()
        }
        do {
            try await origin.server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try #require(origin.http.server.shared.localAddress?.port)
            app.controlPlaneConfiguration = try await ControlPlaneConfiguration.load(
                environmentVariables: ["LOKI_ENDPOINT": "http://127.0.0.1:\(port)"], for: .testing)
            try await test(LokiService(app: app), requests)
        } catch {
            await teardown()
            throw error
        }
        await teardown()
    }

    @Test("A whole batch uses one HTTP request, and non-2xx status reaches the caller", arguments: [204, 429, 503])
    func statusPropagation(code: Int) async throws {
        try await withOrigin(status: .init(statusCode: code)) { service, requests in
            let logs = (0..<100).map { SandboxLogMessage(sandboxId: "s", stream: "stdout", message: "\($0)") }
            if code == 204 {
                try await service.pushSandboxLogs(logs)
            } else {
                await #expect(throws: LokiError.self) { try await service.pushSandboxLogs(logs) }
            }
            #expect(requests.withLockedValue { $0 } == 1)
        }
    }

    @Test("Hung Loki fails within the push deadline")
    func deadline() async throws {
        try await withOrigin(delay: .seconds(5)) { service, requests in
            let start = ContinuousClock.now
            await #expect(throws: (any Error).self) {
                try await service.pushSandboxLogs([SandboxLogMessage(sandboxId: "s", stream: "stdout", message: "x")])
            }
            #expect(start.duration(to: .now) < .seconds(4))
            #expect(requests.withLockedValue { $0 } == 1)
        }
    }

    @Test("Successful headers cannot hide a stalled response body from the deadline")
    func stalledResponseBody() async throws {
        try await withOrigin(status: .ok, bodyDelay: .seconds(5)) { service, requests in
            let start = ContinuousClock.now
            await #expect(throws: (any Error).self) {
                try await service.pushSandboxLogs([SandboxLogMessage(sandboxId: "s", stream: "stdout", message: "x")])
            }
            #expect(start.duration(to: .now) < .seconds(4))
            #expect(requests.withLockedValue { $0 } == 1)
        }
    }

    @Test("Unexpected response bodies cannot grow without a bound")
    func responseLimit() async throws {
        try await withOrigin(status: .ok, bodyBytes: 128 * 1024) { service, _ in
            await #expect(throws: (any Error).self) {
                try await service.pushSandboxLogs([SandboxLogMessage(sandboxId: "s", stream: "stdout", message: "x")])
            }
        }
    }
}
