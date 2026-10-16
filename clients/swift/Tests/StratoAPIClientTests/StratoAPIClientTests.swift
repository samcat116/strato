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
}

@Suite("Generated resource class client contract")
struct ResourceClassClientTests {
    @Test func policyAndSnapshotEncodeFlatAndReferenceIsSiteScoped() throws {
        let policy = Components.Schemas.WorkloadResourceClassPolicy(
            kind: .burstable,
            cpuAllocationRatio: 4, memoryAllocationRatio: 1, cpuWeight: 100,
            memoryHighPercent: 80, hardLimitPolicy: .guestAndBackend,
            maxCPUPressure10: 10, maxMemoryPressure10: 5, maxTelemetryAgeSeconds: 60)
        let snapshot = Components.Schemas.WorkloadResourceClassSnapshot(
            value1: policy,
            value2: .init(classID: "00000000-0000-0000-0000-000000000002", siteID: UUID().uuidString, revision: 3))
        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] as? String == "burstable")
        #expect(object["revision"] as? Int == 3)
        #expect(object["policy"] == nil)
        #expect(try JSONDecoder().decode(Components.Schemas.WorkloadResourceClassSnapshot.self, from: data) == snapshot)
        let request = Components.Schemas.CreateVMRequest(
            resourceClass: .init(
                siteID: snapshot.value2.siteID, classID: snapshot.value2.classID), name: "worker",
            projectId: UUID().uuidString)
        let requestData = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(Components.Schemas.CreateVMRequest.self, from: requestData)
        #expect(decoded.resourceClass?.siteID == snapshot.value2.siteID)
    }
}
