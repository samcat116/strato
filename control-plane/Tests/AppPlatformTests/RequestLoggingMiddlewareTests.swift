import InMemoryLogging
import Testing
import Vapor
import VaporTesting

@testable import App

@Suite("Request logging middleware")
struct RequestLoggingMiddlewareTests {
    @Test("configured pipeline redacts claim, rate-limit, and unmatched paths")
    func configuredPipelineRedactsSecretBearingPaths() async throws {
        try await withHTTPPipelineApp(
            environmentVariables: [
                "REQUEST_LOGGING": "true",
                "RATE_LIMIT_ENABLED": "true",
                "RATE_LIMIT_AUTH_MAX": "1",
            ]
        ) { app, logHandler in
            app.get("auth", "claim", ":token") { request -> Response in
                let token = try request.parameters.require("token")
                throw Abort(.badRequest, reason: "Rejected concrete token: \(token)")
            }

            let sentinelSecret = "STR_282_SENTINEL_SECRET"
            let requestID = "str-282-request-id"
            logHandler.clear()

            try await app.test(
                .GET,
                "/auth/claim/\(sentinelSecret)",
                headers: ["X-Request-ID": requestID]
            ) { response in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("Rejected concrete token: \(sentinelSecret)"))
            }

            let matchedEntry = try #require(singleEntry("http_request", in: logHandler))
            expectRequestMetadata(
                matchedEntry,
                route: "/auth/claim/:token",
                status: "400",
                requestID: requestID)
            #expect(matchedEntry.metadata["error"]?.description == "Vapor.Abort")
            let durationText = try #require(matchedEntry.metadata["durationMs"]?.description)
            let duration = try #require(Double(durationText))
            #expect(duration >= 0)

            let errorEntry = try #require(singleEntry("http_request_error", in: logHandler))
            expectRequestMetadata(
                errorEntry,
                route: "/auth/claim/:token",
                status: "400",
                requestID: requestID)
            #expect(errorEntry.metadata["error"]?.description == "Vapor.Abort")
            #expect(!renderedLogs(logHandler.entries).contains(sentinelSecret))

            logHandler.clear()
            try await app.test(
                .GET,
                "/auth/claim/\(sentinelSecret)",
                headers: ["X-Request-ID": requestID]
            ) { response in
                #expect(response.status == .tooManyRequests)
                #expect(response.headers.first(name: "Retry-After") != nil)
            }

            let rateLimitEntry = try #require(singleEntry("rate_limit_exceeded", in: logHandler))
            #expect(rateLimitEntry.metadata["http.route"]?.description == "/auth/claim/:token")
            #expect(rateLimitEntry.metadata["path"]?.description == "/auth/claim/:token")
            #expect(rateLimitEntry.metadata["scope"]?.description == "auth")
            let limitedEntry = try #require(singleEntry("http_request", in: logHandler))
            expectRequestMetadata(
                limitedEntry,
                route: "/auth/claim/:token",
                status: "429",
                requestID: requestID)
            #expect(!renderedLogs(logHandler.entries).contains(sentinelSecret))

            let unmatchedQuerySecret = "STR_282_QUERY_SECRET"
            logHandler.clear()
            try await app.test(
                .GET,
                "/not-a-route/\(sentinelSecret)?token=\(unmatchedQuerySecret)",
                headers: ["X-Request-ID": requestID]
            ) { response in
                #expect(response.status == .forbidden)
            }

            let authorizationEntry = try #require(
                singleEntry("Request for unclassified path denied", in: logHandler))
            #expect(authorizationEntry.metadata["http.route"]?.description == "unmatched")
            #expect(authorizationEntry.metadata["path"]?.description == "unmatched")
            let unmatchedEntry = try #require(singleEntry("http_request", in: logHandler))
            expectRequestMetadata(
                unmatchedEntry,
                route: "unmatched",
                status: "403",
                requestID: requestID)
            let unmatchedLogs = renderedLogs(logHandler.entries)
            #expect(!unmatchedLogs.contains(sentinelSecret))
            #expect(!unmatchedLogs.contains(unmatchedQuerySecret))
        }
    }

    @Test("sanitized error events remain when access logging is disabled")
    func errorsRemainObservableWithoutAccessLogging() async throws {
        try await withHTTPPipelineApp(
            environmentVariables: [
                "REQUEST_LOGGING": "false",
                "RATE_LIMIT_ENABLED": "false",
            ]
        ) { app, logHandler in
            app.get("auth", "claim", ":token") { request -> Response in
                let token = try request.parameters.require("token")
                throw Abort(.internalServerError, reason: "Failed concrete token: \(token)")
            }

            let sentinelSecret = "STR_282_DISABLED_SENTINEL"
            let requestID = "str-282-disabled-request-id"
            logHandler.clear()

            try await app.test(
                .GET,
                "/auth/claim/\(sentinelSecret)",
                headers: ["X-Request-ID": requestID]
            ) { response in
                #expect(response.status == .internalServerError)
                #expect(response.body.string.contains("Failed concrete token: \(sentinelSecret)"))
            }

            #expect(entries("http_request", in: logHandler).isEmpty)
            let errorEntry = try #require(singleEntry("http_request_error", in: logHandler))
            expectRequestMetadata(
                errorEntry,
                route: "/auth/claim/:token",
                status: "500",
                requestID: requestID)
            #expect(errorEntry.metadata["error"]?.description == "Vapor.Abort")
            #expect(!renderedLogs(logHandler.entries).contains(sentinelSecret))
        }
    }

    private func withHTTPPipelineApp(
        environmentVariables: [String: String],
        _ test: (Application, InMemoryLogHandler) async throws -> Void
    ) async throws {
        let logHandler = InMemoryLogHandler()
        let logger = Logger(label: "request-logging-test") { _ in logHandler }
        let app = try await Application.make(.testing, logger: logger)

        do {
            app.controlPlaneConfiguration = try await ControlPlaneConfiguration.load(
                environmentVariables: environmentVariables,
                for: .testing)
            try app.bootstrapHTTPPipeline()
            try await test(app, logHandler)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }

        try await app.asyncShutdown()
    }

    private func expectRequestMetadata(
        _ entry: InMemoryLogHandler.Entry,
        route: String,
        status: String,
        requestID: String
    ) {
        #expect(entry.metadata["http.route"]?.description == route)
        #expect(entry.metadata["path"]?.description == route)
        #expect(entry.metadata["method"]?.description == "GET")
        #expect(entry.metadata["status"]?.description == status)
        #expect(entry.metadata["request-id"]?.description == requestID)
        #expect(entry.metadata["strato.request.id"]?.description == requestID)
    }

    private func entries(
        _ message: String,
        in handler: InMemoryLogHandler
    ) -> [InMemoryLogHandler.Entry] {
        handler.entries.filter { $0.message.description == message }
    }

    private func singleEntry(
        _ message: String,
        in handler: InMemoryLogHandler
    ) -> InMemoryLogHandler.Entry? {
        let matchingEntries = entries(message, in: handler)
        guard matchingEntries.count == 1 else { return nil }
        return matchingEntries[0]
    }

    private func renderedLogs(_ entries: [InMemoryLogHandler.Entry]) -> String {
        entries.map { entry in
            let metadata = entry.metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            return "\(entry.message) \(metadata) \(entry.error.map { String(reflecting: $0) } ?? "")"
        }.joined(separator: "\n")
    }
}
