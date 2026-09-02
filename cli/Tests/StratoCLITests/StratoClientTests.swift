import Foundation
import HTTPTypes
import OpenAPIRuntime
import StratoAPIClient
import Synchronization
import Testing

@testable import StratoCLICore

/// The generated client plus the CLI's middlewares: bearer auth with
/// refresh-on-401, and non-2xx responses mapped to `CLIError`.
@Suite("StratoClient")
struct StratoClientTests {
    let baseURL = URL(string: "https://strato.example.com")!

    static let operationID = "6f9619ff-8b86-4d01-b42d-00cf4fc964ff"
    static let operationJSON = """
        {"id": "\(operationID)", "resourceKind": "virtual_machine",
         "resourceId": "\(operationID)", "kind": "boot", "status": "succeeded"}
        """
    static let tokenJSON = """
        {"access_token": "st_new", "token_type": "Bearer", "expires_in": 3600,
         "refresh_token": "rt_new"}
        """

    private func makeClient(
        transport: MockTransport, directory: URL, expiresAt: Date? = nil
    ) throws -> any APIProtocol {
        let store = CredentialStore(directory: directory)
        try store.store(
            StoredCredentials(accessToken: "st_old", refreshToken: "rt_old", expiresAt: expiresAt),
            for: "test")
        return StratoClient.authenticatedSession(
            serverURL: baseURL, contextName: "test", credentialStore: store, transport: transport
        ).client
    }

    @Test("Mutation middleware generates one key and preserves an explicit caller key")
    func testMutationIdempotencyKey() async throws {
        let header = HTTPField.Name("Idempotency-Key")!
        let captured = Mutex<[HTTPRequest]>([])
        let middleware = IdempotencyKeyMiddleware()
        let next:
            @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (
                HTTPResponse, HTTPBody?
            ) = { request, _, _ in
                captured.withLock { $0.append(request) }
                return (HTTPResponse(status: .accepted), nil)
            }

        _ = try await middleware.intercept(
            HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/api/vms"),
            body: HTTPBody(Data(#"{"name":"db"}"#.utf8)),
            baseURL: baseURL,
            operationID: "createVM",
            next: next)

        var explicit = HTTPRequest(
            method: .delete, scheme: nil, authority: nil, path: "/api/vms/one")
        explicit.headerFields[header] = "command-invocation-key"
        _ = try await middleware.intercept(
            explicit,
            body: nil,
            baseURL: baseURL,
            operationID: "deleteVM",
            next: next)

        let requests = captured.withLock { $0 }
        #expect(UUID(uuidString: requests[0].headerFields[header] ?? "") != nil)
        #expect(requests[1].headerFields[header] == "command-invocation-key")
    }

    @Test("Sends bearer token, builds the operation's path, and decodes the response")
    func testAuthenticatedGet() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [.init(statusCode: 200, json: Self.operationJSON)])
            let client = try makeClient(transport: transport, directory: directory)

            let operation =
                try await client
                .getOperation(path: .init(operationID: Self.operationID)).ok.body.json
            #expect(operation.succeeded)
            #expect(operation.kind == .boot)

            let request = try #require(transport.recordedRequests.first)
            #expect(request.path == "/api/operations/\(Self.operationID)")
            #expect(request.authorization == "Bearer st_old")
        }
    }

    @Test("Query parameters from the spec reach the wire")
    func testListQuery() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let page = #"{"items": [], "total": 0, "limit": 500, "offset": 0}"#
            let transport = MockTransport(responses: [.init(statusCode: 200, json: page)])
            let client = try makeClient(transport: transport, directory: directory)

            let result = try await client.listVMs(query: .init(limit: listPageLimit)).ok.body.json
            #expect(result.total == 0)

            let request = try #require(transport.recordedRequests.first)
            #expect(request.path == "/api/vms")
            #expect(request.query == "limit=500")
        }
    }

    @Test("On 401: refreshes once, persists the rotated pair, and retries")
    func testRefreshOn401() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 401, json: #"{"error": true, "reason": "Unauthorized"}"#),
                .init(statusCode: 200, json: Self.tokenJSON),
                .init(statusCode: 200, json: Self.operationJSON),
            ])
            let client = try makeClient(transport: transport, directory: directory)

            let operation =
                try await client
                .getOperation(path: .init(operationID: Self.operationID)).ok.body.json
            #expect(operation.succeeded)

            let requests = transport.recordedRequests
            #expect(requests.count == 3)
            #expect(requests[1].path == "/oauth/token")
            #expect(requests[1].bodyText == "grant_type=refresh_token&refresh_token=rt_old")
            #expect(requests[2].authorization == "Bearer st_new")

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
                .init(statusCode: 401, json: #"{"error": true, "reason": "Unauthorized"}"#),
                .init(statusCode: 400, json: #"{"error": "invalid_grant"}"#),
            ])
            let client = try makeClient(transport: transport, directory: directory)

            let error = await #expect(throws: (any Error).self) {
                try await client.getOperation(path: .init(operationID: Self.operationID))
            }
            let thrown = try #require(error)
            guard case .notLoggedIn = try #require(CLIError.from(thrown)) else {
                Issue.record("Expected notLoggedIn")
                return
            }
            #expect(try CredentialStore(directory: directory).credentials(for: "test") == nil)
        }
    }

    @Test("An already-expired access token refreshes proactively before the request")
    func testProactiveRefresh() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 200, json: Self.tokenJSON),
                .init(statusCode: 200, json: Self.operationJSON),
            ])
            let client = try makeClient(
                transport: transport, directory: directory,
                expiresAt: Date().addingTimeInterval(-60))

            _ = try await client.getOperation(path: .init(operationID: Self.operationID)).ok.body.json

            let requests = transport.recordedRequests
            #expect(requests.first?.path == "/oauth/token")
            #expect(requests.last?.authorization == "Bearer st_new")
        }
    }

    @Test("Server errors surface the {reason} body as a CLIError")
    func testErrorBody() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 403, json: #"{"error": true, "reason": "Missing scope"}"#)
            ])
            let client = try makeClient(transport: transport, directory: directory)

            let error = await #expect(throws: (any Error).self) {
                try await client.getOperation(path: .init(operationID: Self.operationID))
            }
            let thrown = try #require(error)
            guard case .api(let status, let message) = try #require(CLIError.from(thrown)) else {
                Issue.record("Expected an api error")
                return
            }
            #expect(status == 403)
            #expect(message == "Missing scope")
        }
    }

    @Test("Missing credentials fail fast with a login hint")
    func testNotLoggedIn() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let client = StratoClient.authenticatedSession(
                serverURL: baseURL, contextName: "nope",
                credentialStore: CredentialStore(directory: directory),
                transport: MockTransport(responses: [])
            ).client

            let error = await #expect(throws: (any Error).self) {
                try await client.getOperation(path: .init(operationID: Self.operationID))
            }
            let thrown = try #require(error)
            guard case .notLoggedIn = try #require(CLIError.from(thrown)) else {
                Issue.record("Expected notLoggedIn")
                return
            }
        }
    }

    @Test("A response body the spec does not describe is reported as contract drift")
    func testResponseBodyDrift() async throws {
        try await withTemporaryDirectoryAsync { directory in
            // `status` is a closed enum in the spec; a value outside it means
            // the control plane is ahead of this binary.
            let drifted = Self.operationJSON.replacingOccurrences(of: "succeeded", with: "quantum")
            let transport = MockTransport(responses: [.init(statusCode: 200, json: drifted)])
            let client = try makeClient(transport: transport, directory: directory)

            let error = await #expect(throws: (any Error).self) {
                try await client.getOperation(path: .init(operationID: Self.operationID))
            }
            let thrown = try #require(error)
            guard case .unexpectedResponse = try #require(CLIError.from(thrown)) else {
                Issue.record("Expected unexpectedResponse")
                return
            }
        }
    }

    /// The status path is separate from the body path above: an undocumented
    /// *success* status sails past `ErrorMappingMiddleware`, and the generated
    /// `.ok` accessor then throws in the caller's frame rather than inside the
    /// runtime's `ClientError`. It still has to reach the user as drift.
    @Test("A success status the spec does not describe is reported as contract drift")
    func testResponseStatusDrift() async throws {
        try await withTemporaryDirectoryAsync { directory in
            // `getOperation` documents 200 only.
            let transport = MockTransport(responses: [.init(statusCode: 201, json: Self.operationJSON)])
            let client = try makeClient(transport: transport, directory: directory)

            let error = await #expect(throws: (any Error).self) {
                try await client.getOperation(path: .init(operationID: Self.operationID)).ok
            }
            let thrown = try #require(error)
            guard case .unexpectedResponse = try #require(CLIError.from(thrown)) else {
                Issue.record("Expected unexpectedResponse, got \(String(describing: CLIError.from(thrown)))")
                return
            }
        }
    }

    /// The refresh dedupe is the subtlest logic in the client: replaying an
    /// already-rotated refresh token revokes the session server-side, so a
    /// burst of parallel 401s must produce exactly one `/oauth/token` call.
    @Test("Concurrent 401s share one refresh instead of racing it")
    func testConcurrentRefreshIsDeduped() async throws {
        try await withTemporaryDirectoryAsync { directory in
            // Answered by content, not by arrival order: with requests in
            // flight together the order is undefined.
            let transport = MockTransport { request in
                if request.path == "/oauth/token" {
                    return .init(statusCode: 200, json: Self.tokenJSON)
                }
                guard request.authorization == "Bearer st_new" else {
                    return .init(statusCode: 401, json: #"{"error": true, "reason": "Unauthorized"}"#)
                }
                return .init(statusCode: 200, json: Self.operationJSON)
            }
            let client = try makeClient(transport: transport, directory: directory)

            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        _ =
                            try await client
                            .getOperation(path: .init(operationID: Self.operationID)).ok.body.json
                    }
                }
                try await group.waitForAll()
            }

            let refreshes = transport.recordedRequests.filter { $0.path == "/oauth/token" }
            #expect(refreshes.count == 1)
            // Every caller still got through, each on the rotated token.
            let reads = transport.recordedRequests.filter { $0.path != "/oauth/token" }
            #expect(reads.filter { $0.authorization == "Bearer st_new" }.count == 8)
        }
    }

    /// A rejected grant and an unreachable endpoint are different verdicts: only
    /// the former means the session is gone.
    @Test("A transient failure at the token endpoint leaves credentials intact")
    func testRefreshTransientFailure() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 401, json: #"{"error": true, "reason": "Unauthorized"}"#),
                .init(statusCode: 502, json: "<html>Bad Gateway</html>"),
            ])
            let client = try makeClient(transport: transport, directory: directory)

            let error = await #expect(throws: (any Error).self) {
                try await client.getOperation(path: .init(operationID: Self.operationID))
            }
            let thrown = try #require(error)
            guard case .api(let status, _) = try #require(CLIError.from(thrown)) else {
                Issue.record("Expected an api error, got \(String(describing: CLIError.from(thrown)))")
                return
            }
            #expect(status == 502)

            // The refresh token survives, so the next invocation can retry
            // instead of sending the user back through the browser.
            let stored = try CredentialStore(directory: directory).credentials(for: "test")
            #expect(stored?.refreshToken == "rt_old")
        }
    }

    /// The `guard`/rethrow in `runHandlingCLIErrors` is load-bearing for
    /// ArgumentParser's own control-flow errors and for ordinary failures like
    /// an unreadable `--ssh-key-file`, so `from` must not claim everything.
    @Test("An error that is not the API layer's keeps bubbling")
    func testUnrelatedErrorIsNotClaimed() {
        struct Unrelated: Error {}
        #expect(CLIError.from(Unrelated()) == nil)
        #expect(CLIError.from(CocoaError(.fileNoSuchFile)) == nil)
    }

    @Test("A 204 endpoint completes with no body")
    func testNoContentResponse() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [.empty()])
            let client = try makeClient(transport: transport, directory: directory)

            _ = try await client.deleteNetwork(path: .init(networkId: Self.operationID)).noContent

            let request = try #require(transport.recordedRequests.first)
            #expect(request.request.method == .delete)
            #expect(request.path == "/api/networks/\(Self.operationID)")
        }
    }
}
