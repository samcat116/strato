import Foundation
import Testing

@testable import StratoCLICore

@Suite("OperationWaiter")
struct OperationWaiterTests {
    private func operation(status: String, error: String? = nil) -> ResourceOperation {
        let json = """
            {"id": "6f9619ff-8b86-4d01-b42d-00cf4fc964ff", "kind": "boot",
             "status": "\(status)", "resourceKind": "virtual_machine",
             "resourceId": "6f9619ff-8b86-4d01-b42d-00cf4fc964ff"
             \(error.map { #", "error": "\#($0)""# } ?? "")}
            """
        return try! APIClient.jsonDecoder().decode(ResourceOperation.self, from: Data(json.utf8))
    }

    private func client(transport: MockTransport, directory: URL) throws -> APIClient {
        let store = CredentialStore(directory: directory)
        try store.store(StoredCredentials(accessToken: "st_x", refreshToken: "rt_x"), for: "test")
        return APIClient(
            baseURL: URL(string: "https://strato.example.com")!, contextName: "test",
            credentialStore: store, transport: transport)
    }

    @Test("Polls until the operation succeeds")
    func testWaitsForSuccess() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let pending = """
                {"id": "6f9619ff-8b86-4d01-b42d-00cf4fc964ff", "kind": "boot", "status": "pending",
                 "resourceKind": "virtual_machine", "resourceId": "6f9619ff-8b86-4d01-b42d-00cf4fc964ff"}
                """
            let succeeded = pending.replacingOccurrences(of: "pending", with: "succeeded")
            let transport = MockTransport(responses: [
                .init(statusCode: 200, json: pending),
                .init(statusCode: 200, json: succeeded),
            ])
            let waiter = OperationWaiter(pollInterval: 0, timeout: 60, sleeper: { _ in })

            let final = try await waiter.wait(
                for: operation(status: "pending"),
                client: try client(transport: transport, directory: directory))
            #expect(final.succeeded)
            #expect(transport.recordedRequests.count == 2)
            #expect(
                transport.recordedRequests.first?.url.path
                    == "/api/operations/6F9619FF-8B86-4D01-B42D-00CF4FC964FF")
        }
    }

    @Test("A failed operation throws with its error message")
    func testFailure() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [])
            let waiter = OperationWaiter(pollInterval: 0, timeout: 60, sleeper: { _ in })

            do {
                try await waiter.wait(
                    for: operation(status: "failed", error: "no capacity"),
                    client: try client(transport: transport, directory: directory))
                Issue.record("Expected operationFailed")
            } catch let error as CLIError {
                guard case .operationFailed(let kind, let message) = error else {
                    Issue.record("Unexpected error \(error)")
                    return
                }
                #expect(kind == "boot")
                #expect(message == "no capacity")
            }
        }
    }

    @Test("An already-terminal operation returns without polling")
    func testTerminalShortCircuit() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [])
            let waiter = OperationWaiter(pollInterval: 0, timeout: 60, sleeper: { _ in })
            let final = try await waiter.wait(
                for: operation(status: "succeeded"),
                client: try client(transport: transport, directory: directory))
            #expect(final.succeeded)
            #expect(transport.recordedRequests.isEmpty)
        }
    }

    @Test("Gives up at the timeout")
    func testTimeout() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [])
            let waiter = OperationWaiter(pollInterval: 0, timeout: 0, sleeper: { _ in })
            await #expect(throws: CLIError.self) {
                try await waiter.wait(
                    for: operation(status: "pending"),
                    client: try client(transport: transport, directory: directory))
            }
        }
    }
}
