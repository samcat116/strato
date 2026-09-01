import InMemoryLogging
import Testing
import Vapor
import VaporTesting

@testable import App

@Suite("Request logging middleware")
struct RequestLoggingMiddlewareTests {
    @Test("account-claim and unmatched requests never log concrete paths")
    func secretBearingPathsAreRedacted() async throws {
        let logHandler = InMemoryLogHandler()
        let logger = Logger(label: "request-logging-test") { _ in logHandler }
        let app = try await Application.make(.testing, logger: logger)

        do {
            app.configureRequestLogging(enabled: true)
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

            let matchedEntry = try #require(singleRequestEntry(in: logHandler))
            #expect(matchedEntry.metadata["http.route"]?.description == "/auth/claim/:token")
            #expect(matchedEntry.metadata["path"]?.description == "/auth/claim/:token")
            #expect(matchedEntry.metadata["method"]?.description == "GET")
            #expect(matchedEntry.metadata["status"]?.description == "400")
            #expect(matchedEntry.metadata["request-id"]?.description == requestID)
            #expect(matchedEntry.metadata["error"]?.description == "Vapor.Abort")
            let durationText = try #require(matchedEntry.metadata["durationMs"]?.description)
            let duration = try #require(Double(durationText))
            #expect(duration >= 0)
            #expect(!renderedLogs(logHandler.entries).contains(sentinelSecret))

            let unmatchedQuerySecret = "STR_282_QUERY_SECRET"
            logHandler.clear()
            try await app.test(
                .GET,
                "/not-a-route/\(sentinelSecret)?token=\(unmatchedQuerySecret)",
                headers: ["X-Request-ID": requestID]
            ) { response in
                #expect(response.status == .notFound)
            }

            let unmatchedEntry = try #require(singleRequestEntry(in: logHandler))
            #expect(unmatchedEntry.metadata["http.route"]?.description == "unmatched")
            #expect(unmatchedEntry.metadata["path"]?.description == "unmatched")
            #expect(unmatchedEntry.metadata["method"]?.description == "GET")
            #expect(unmatchedEntry.metadata["status"]?.description == "404")
            #expect(unmatchedEntry.metadata["request-id"]?.description == requestID)
            let unmatchedLogs = renderedLogs(logHandler.entries)
            #expect(!unmatchedLogs.contains(sentinelSecret))
            #expect(!unmatchedLogs.contains(unmatchedQuerySecret))
        } catch {
            try? await app.asyncShutdown()
            throw error
        }

        try await app.asyncShutdown()
    }

    private func singleRequestEntry(in handler: InMemoryLogHandler) -> InMemoryLogHandler.Entry? {
        let entries = handler.entries.filter { $0.message.description == "http_request" }
        guard entries.count == 1 else { return nil }
        return entries[0]
    }

    private func renderedLogs(_ entries: [InMemoryLogHandler.Entry]) -> String {
        entries.map { entry in
            let metadata = entry.metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            return "\(entry.message) \(metadata) \(entry.error.map { String(reflecting: $0) } ?? "")"
        }.joined(separator: "\n")
    }
}
