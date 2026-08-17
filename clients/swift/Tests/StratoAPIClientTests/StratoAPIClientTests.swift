import Foundation
import HTTPTypes
import OpenAPIRuntime
import Synchronization
import Testing

@testable import StratoAPIClient

/// Smoke tests for the generated client package.
///
/// The generated code itself is swift-openapi-generator's responsibility; what
/// is worth testing here is that the package wires up — the spec symlink
/// resolves, the client conforms to the generated protocol over a transport, and
/// the hand-written middleware does what it claims.
@Suite("Strato API client")
struct StratoAPIClientTests {

    /// A transport that answers every request from a canned response, recording
    /// what it was asked for.
    final class RecordingTransport: ClientTransport, Sendable {
        private let recordedRequest = Mutex<HTTPRequest?>(nil)
        var lastRequest: HTTPRequest? { recordedRequest.withLock { $0 } }
        let response: HTTPResponse
        let responseBody: HTTPBody?

        init(response: HTTPResponse, responseBody: HTTPBody?) {
            self.response = response
            self.responseBody = responseBody
        }

        func send(
            _ request: HTTPRequest,
            body: HTTPBody?,
            baseURL: URL,
            operationID: String
        ) async throws -> (HTTPResponse, HTTPBody?) {
            recordedRequest.withLock { $0 = request }
            return (response, responseBody)
        }
    }

    @Test("The client calls the spec's path and decodes the spec's schema")
    func listsProjects() async throws {
        let body = """
            [{
              "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
              "name": "Web Application",
              "description": "Main web application project",
              "path": "/org/web",
              "defaultEnvironment": "development",
              "environments": ["development", "production"],
              "vmCount": 2
            }]
            """
        let transport = RecordingTransport(
            response: HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
            responseBody: HTTPBody(body)
        )
        let client = Client(
            serverURL: URL(string: "https://strato.example.com")!,
            transport: transport,
            middlewares: [BearerTokenMiddleware(token: "strato_test_key")]
        )

        let output = try await client.listProjects()
        let projects = try output.ok.body.json

        #expect(projects.count == 1)
        #expect(projects.first?.name == "Web Application")
        #expect(projects.first?.environments == ["development", "production"])
        #expect(transport.lastRequest?.path == "/api/projects")
        #expect(transport.lastRequest?.headerFields[.authorization] == "Bearer strato_test_key")
    }

    @Test("Documented error responses decode as their typed case")
    func decodesErrorEnvelope() async throws {
        let transport = RecordingTransport(
            response: HTTPResponse(status: .notFound, headerFields: [.contentType: "application/json"]),
            responseBody: HTTPBody(#"{"error": true, "reason": "Project not found"}"#)
        )
        let client = Client(
            serverURL: URL(string: "https://strato.example.com")!,
            transport: transport
        )

        let output = try await client.getProject(
            path: .init(projectID: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        )
        guard case .notFound(let notFound) = output else {
            Issue.record("Expected the documented 404 case, got \(output)")
            return
        }
        let payload = try notFound.body.json
        #expect(payload.reason == "Project not found")
    }

    @Test("Creates a typed multiplexed sandbox exec session")
    func createsSandboxExecSession() async throws {
        let body = """
            {"sessionId":"session-1",
             "websocketPath":"/api/sandboxes/sandbox-1/exec/session-1/attach",
             "expiresAt":"2099-01-01T00:00:00Z",
             "outputMode":"multiplexed"}
            """
        let transport = RecordingTransport(
            response: HTTPResponse(status: .created, headerFields: [.contentType: "application/json"]),
            responseBody: HTTPBody(body)
        )
        let client = Client(
            serverURL: URL(string: "https://strato.example.com")!, transport: transport)

        let session = try await client.createSandboxExecSession(
            path: .init(sandboxID: "sandbox-1"),
            body: .json(
                .init(
                    command: ["/bin/echo", "hello"], tty: false,
                    outputMode: .multiplexed))
        ).created.body.json

        #expect(session.sessionId == "session-1")
        #expect(session.outputMode == .multiplexed)
        #expect(transport.lastRequest?.path == "/api/sandboxes/sandbox-1/exec")
    }
}
