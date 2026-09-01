import AppTestSupport
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

    @Test("The configured pipeline redacts claim tokens from throttling and errors")
    func configuredPipelineRedactsClaimTokens() async throws {
        let validSecret = "CLAIM_RATE_LIMIT_SENTINEL_STR_285"
        let invalidSecret = "CLAIM_ERROR_SENTINEL_STR_285"
        let capture = InMemoryLogCapture(label: "configured-pipeline-contract")
        let app = try await Application.makeForTesting()
        app.logger = capture.logger

        do {
            try await configure(
                app,
                environmentVariables: [
                    "RATE_LIMIT_ENABLED": "true",
                    "RATE_LIMIT_AUTH_MAX": "10",
                    "RATE_LIMIT_FAILURE_THRESHOLD": "100",
                    "REQUEST_LOGGING": "true",
                ])

            let user = try await TestDataBuilder(db: app.db).createUser(
                username: "logging-contract-user",
                email: "logging-contract@example.com")
            let claim = AccountClaimToken(
                userID: try user.requireID(),
                tokenHash: AccountClaimToken.hashToken(validSecret),
                tokenPrefix: AccountClaimToken.extractPrefix(validSecret),
                expiresAt: Date().addingTimeInterval(3_600),
                createdByID: nil)
            try await claim.save(on: app.db)

            for _ in 0..<10 {
                try await app.test(.GET, "/auth/claim/\(validSecret)") { response async throws in
                    #expect(response.status == .ok)
                }
            }
            try await app.test(.GET, "/auth/claim/\(validSecret)") { response async throws in
                #expect(response.status == .tooManyRequests)
            }

            try await app.test(
                .GET,
                "/auth/claim/\(invalidSecret)",
                headers: ["X-Forwarded-For": "203.0.113.20"]
            ) { response async throws in
                #expect(response.status == .notFound)
            }
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()

        let rateLimitEntry = try #require(
            capture.handler.entries.first { $0.message == "rate_limit_exceeded" })
        #expect(rateLimitEntry.metadata["path"] == "/auth/claim/:token")
        let errorEntry = try #require(
            capture.handler.entries.first { $0.metadata["url"] != nil })
        #expect(errorEntry.metadata["url"] == "/auth/claim/:token")
        capture.expectNoSecrets([validSecret, invalidSecret])
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
