import InMemoryLogging
import Logging
import Testing
import Vapor
import VaporTesting

@testable import App

@Suite("Logging contracts")
struct LoggingContractTests {
    private enum RouteFailure: Error {
        case failed
    }

    @Test("Request logs use the matched route and never expose path credentials")
    func requestRouteIsRedacted() async throws {
        let secret = "CLAIM_TOKEN_SENTINEL_STR_285"
        let capture = InMemoryLogCapture(label: "request-route-contract")

        try await withApplication(logger: capture.logger) { app in
            app.installSecretSafeBaseMiddleware()
            app.middleware.use(RequestLoggingMiddleware())
            app.get("auth", "claim", ":token") { _ in HTTPStatus.noContent }

            try await app.test(.GET, "/auth/claim/\(secret)") { response async throws in
                #expect(response.status == .noContent)
            }
        }

        let requestEntries = capture.handler.entries.filter { $0.message == "http_request" }
        let entry = try #require(requestEntries.first)
        #expect(requestEntries.count == 1)
        #expect(entry.level == .info)
        #expect(entry.message == "http_request")
        #expect(entry.error == nil)
        #expect(entry.metadata["method"] == "GET")
        #expect(entry.metadata["path"] == "/auth/claim/:token")
        #expect(entry.metadata["status"] == .stringConvertible(204))
        #expect(entry.metadata["durationMs"] != nil)
        capture.expectNoSecrets([secret])
    }

    @Test("Request failures retain their typed error")
    func requestFailureRetainsTypedError() async throws {
        let capture = InMemoryLogCapture(label: "request-error-contract")

        try await withApplication(logger: capture.logger) { app in
            app.installSecretSafeBaseMiddleware()
            app.middleware.use(RequestLoggingMiddleware())
            app.get("contract-error") { _ async throws -> HTTPStatus in
                throw RouteFailure.failed
            }

            try await app.test(.GET, "/contract-error") { response async throws in
                #expect(response.status == .internalServerError)
            }
        }

        let entry = try #require(
            capture.handler.entries.first { $0.message == "http_request" })
        #expect(entry.level == .error)
        #expect(entry.message == "http_request")
        let error = try #require(entry.error)
        #expect(error is RouteFailure)
        #expect(entry.metadata["path"] == "/contract-error")
        #expect(entry.metadata["status"] == .stringConvertible(500))
        #expect(entry.metadata["error"] == nil)
    }

    @Test("Request metadata remains task-local across structured async work")
    func requestMetadataCrossesAsyncBoundary() async throws {
        let capture = InMemoryLogCapture(label: "request-context-contract")

        try await withApplication(logger: capture.logger) { app in
            app.installSecretSafeBaseMiddleware()
            app.middleware.use(RequestLogMetadataMiddleware())
            app.get("task-local-logger") { _ async -> HTTPStatus in
                await Task {
                    Logger.current.info("task_local_request")
                }.value
                return .noContent
            }

            try await app.test(
                .GET,
                "/task-local-logger",
                headers: ["X-Request-ID": "request-str-285"]
            ) { response async throws in
                #expect(response.status == .noContent)
            }
        }

        let taskLocalEntries = capture.handler.entries.filter { $0.message == "task_local_request" }
        let entry = try #require(taskLocalEntries.first)
        #expect(taskLocalEntries.count == 1)
        #expect(entry.message == "task_local_request")
        #expect(entry.metadata["request-id"] == "request-str-285")
        #expect(entry.metadata["strato.request.id"] == "request-str-285")
    }

    private func withApplication(
        logger: Logger,
        _ body: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        app.logger = logger
        do {
            try await body(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
