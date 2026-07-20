import Foundation
import Testing

@testable import StratoCLICore

@Suite("APIClient")
struct APIClientTests {
    let baseURL = URL(string: "https://strato.example.com")!

    private func makeClient(
        transport: MockTransport, directory: URL, expiresAt: Date? = nil
    ) throws -> APIClient {
        let store = CredentialStore(directory: directory)
        try store.store(
            StoredCredentials(accessToken: "st_old", refreshToken: "rt_old", expiresAt: expiresAt),
            for: "test")
        return APIClient(
            baseURL: baseURL, contextName: "test", credentialStore: store, transport: transport)
    }

    struct Ping: Codable, Equatable {
        let ok: Bool
    }

    @Test("Sends bearer token and decodes JSON")
    func testAuthenticatedGet() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [.init(statusCode: 200, json: #"{"ok": true}"#)])
            let client = try makeClient(transport: transport, directory: directory)

            let result: Ping = try await client.get("/api/ping")
            #expect(result == Ping(ok: true))

            let request = try #require(transport.recordedRequests.first)
            #expect(request.headers["Authorization"] == "Bearer st_old")
        }
    }

    @Test("On 401: refreshes once, persists the rotated pair, and retries")
    func testRefreshOn401() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 401, json: #"{"reason": "Unauthorized"}"#),
                .init(
                    statusCode: 200,
                    json: """
                        {"access_token": "st_new", "token_type": "Bearer", "expires_in": 3600,
                         "refresh_token": "rt_new", "scope": "read write"}
                        """),
                .init(statusCode: 200, json: #"{"ok": true}"#),
            ])
            let client = try makeClient(transport: transport, directory: directory)

            let result: Ping = try await client.get("/api/ping")
            #expect(result == Ping(ok: true))

            let requests = transport.recordedRequests
            #expect(requests.count == 3)
            #expect(requests[1].url.path == "/oauth/token")
            let refreshBody = String(decoding: try #require(requests[1].body), as: UTF8.self)
            #expect(refreshBody.contains("grant_type=refresh_token"))
            #expect(refreshBody.contains("refresh_token=rt_old"))
            #expect(requests[2].headers["Authorization"] == "Bearer st_new")

            // The rotated pair was persisted for the next invocation.
            let stored = try CredentialStore(directory: directory).credentials(for: "test")
            #expect(stored?.accessToken == "st_new")
            #expect(stored?.refreshToken == "rt_new")
        }
    }

    @Test("A rejected refresh clears credentials and asks for a fresh login")
    func testRefreshRejected() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 401, json: #"{"reason": "Unauthorized"}"#),
                .init(statusCode: 400, json: #"{"error": "invalid_grant"}"#),
            ])
            let client = try makeClient(transport: transport, directory: directory)

            await #expect(throws: CLIError.self) {
                let _: Ping = try await client.get("/api/ping")
            }
            #expect(try CredentialStore(directory: directory).credentials(for: "test") == nil)
        }
    }

    @Test("An already-expired access token refreshes proactively before the request")
    func testProactiveRefresh() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(
                    statusCode: 200,
                    json: """
                        {"access_token": "st_new", "token_type": "Bearer", "expires_in": 3600,
                         "refresh_token": "rt_new", "scope": "read write"}
                        """),
                .init(statusCode: 200, json: #"{"ok": true}"#),
            ])
            let client = try makeClient(
                transport: transport, directory: directory,
                expiresAt: Date().addingTimeInterval(-60))

            let result: Ping = try await client.get("/api/ping")
            #expect(result == Ping(ok: true))

            let requests = transport.recordedRequests
            #expect(requests.first?.url.path == "/oauth/token")
            #expect(requests.last?.headers["Authorization"] == "Bearer st_new")
        }
    }

    @Test("Server errors surface the {reason} body")
    func testErrorBody() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 403, json: #"{"error": true, "reason": "Missing scope"}"#)
            ])
            let client = try makeClient(transport: transport, directory: directory)

            do {
                let _: Ping = try await client.get("/api/ping")
                Issue.record("Expected an error")
            } catch let error as CLIError {
                guard case .api(let status, let message) = error else {
                    Issue.record("Unexpected error \(error)")
                    return
                }
                #expect(status == 403)
                #expect(message == "Missing scope")
            }
        }
    }

    @Test("Missing credentials fail fast with a login hint")
    func testNotLoggedIn() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let client = APIClient(
                baseURL: baseURL, contextName: "nope",
                credentialStore: CredentialStore(directory: directory),
                transport: MockTransport(responses: []))
            await #expect(throws: CLIError.self) {
                let _: Ping = try await client.get("/api/ping")
            }
        }
    }
}

/// Async-friendly variant of `withTemporaryDirectory`.
func withTemporaryDirectoryAsync<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("strato-cli-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}
