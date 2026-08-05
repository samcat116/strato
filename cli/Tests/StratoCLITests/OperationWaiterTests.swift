import Foundation
import StratoAPIClient
import Testing

@testable import StratoCLICore

@Suite("OperationWaiter")
struct OperationWaiterTests {
    private static let operationID = "6f9619ff-8b86-4d01-b42d-00cf4fc964ff"

    private func operation(
        status: Components.Schemas.OperationStatus, error: String? = nil
    ) -> ResourceOperation {
        .init(
            id: Self.operationID, vmId: Self.operationID, resourceKind: .virtualMachine,
            resourceId: Self.operationID, kind: .boot, status: status, error: error)
    }

    private static func json(status: String) -> String {
        """
        {"id": "\(operationID)", "vmId": "\(operationID)", "resourceKind": "virtual_machine",
         "resourceId": "\(operationID)", "kind": "boot", "status": "\(status)"}
        """
    }

    private func client(transport: MockTransport, directory: URL) throws -> any APIProtocol {
        let store = CredentialStore(directory: directory)
        try store.store(StoredCredentials(accessToken: "st_x", refreshToken: "rt_x"), for: "test")
        return StratoClient.authenticated(
            serverURL: URL(string: "https://strato.example.com")!, contextName: "test",
            credentialStore: store, transport: transport)
    }

    @Test("Polls until the operation succeeds")
    func testWaitsForSuccess() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 200, json: Self.json(status: "pending")),
                .init(statusCode: 200, json: Self.json(status: "succeeded")),
            ])
            let waiter = OperationWaiter(pollInterval: 0, timeout: 60, sleeper: { _ in })

            let final = try await waiter.wait(
                for: operation(status: .pending),
                client: try client(transport: transport, directory: directory))
            #expect(final.succeeded)
            #expect(transport.recordedRequests.count == 2)
            #expect(transport.recordedRequests.first?.path == "/api/operations/\(Self.operationID)")
        }
    }

    @Test("A failed operation throws with its error message")
    func testFailure() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [])
            let waiter = OperationWaiter(pollInterval: 0, timeout: 60, sleeper: { _ in })

            do {
                try await waiter.wait(
                    for: operation(status: .failed, error: "no capacity"),
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
                for: operation(status: .succeeded),
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
                    for: operation(status: .pending),
                    client: try client(transport: transport, directory: directory))
            }
        }
    }
}
