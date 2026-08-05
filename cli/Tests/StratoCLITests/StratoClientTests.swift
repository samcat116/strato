import Foundation
import StratoAPIClient
import Testing

@testable import StratoCLICore

/// The generated client plus the CLI's middlewares: bearer auth with
/// refresh-on-401, and non-2xx responses mapped to `CLIError`.
@Suite("StratoClient")
struct StratoClientTests {
    let baseURL = URL(string: "https://strato.example.com")!

    static let operationID = "6f9619ff-8b86-4d01-b42d-00cf4fc964ff"
    static let operationJSON = """
        {"id": "\(operationID)", "vmId": "\(operationID)", "resourceKind": "virtual_machine",
         "resourceId": "\(operationID)", "kind": "boot", "status": "succeeded"}
        """
    static let tokenJSON = """
        {"access_token": "st_new", "token_type": "Bearer", "expires_in": 3600,
         "refresh_token": "rt_new", "scope": "read write"}
        """

    private func makeClient(
        transport: MockTransport, directory: URL, expiresAt: Date? = nil
    ) throws -> any APIProtocol {
        let store = CredentialStore(directory: directory)
        try store.store(
            StoredCredentials(accessToken: "st_old", refreshToken: "rt_old", expiresAt: expiresAt),
            for: "test")
        return StratoClient.authenticated(
            serverURL: baseURL, contextName: "test", credentialStore: store, transport: transport)
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
            #expect(requests[1].bodyText.contains("grant_type=refresh_token"))
            #expect(requests[1].bodyText.contains("refresh_token=rt_old"))
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
            let client = StratoClient.authenticated(
                serverURL: baseURL, contextName: "nope",
                credentialStore: CredentialStore(directory: directory),
                transport: MockTransport(responses: []))

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

    @Test("A response the spec does not describe is reported as contract drift")
    func testResponseDrift() async throws {
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
}
