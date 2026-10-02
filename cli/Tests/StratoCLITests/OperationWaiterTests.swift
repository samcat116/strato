import Foundation
import StratoAPIClient
import Testing

@testable import StratoCLICore

/// Counts the waiter's sleeps, which the `Sendable` sleeper closure cannot do
/// with a captured `var`.
private actor SleepCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

@Suite("OperationWaiter")
struct OperationWaiterTests {
    private static let operationID = "6f9619ff-8b86-4d01-b42d-00cf4fc964ff"

    private static func json(
        status: String, error: String? = nil,
        resourceKind: String = "virtual_machine", kind: String = "boot"
    ) -> String {
        let errorField = error.map { ", \"error\": \"\($0)\"" } ?? ""
        return """
            {"id": "\(operationID)", "resourceKind": "\(resourceKind)",
             "resourceId": "\(operationID)", "kind": "\(kind)", "status": "\(status)"\(errorField)}
            """
    }

    private func client(transport: MockTransport, directory: URL) throws -> any APIProtocol {
        let store = CredentialStore(directory: directory)
        try store.store(StoredCredentials(accessToken: "st_x", refreshToken: "rt_x"), for: "test")
        return StratoClient.authenticatedSession(
            serverURL: URL(string: "https://strato.example.com")!, contextName: "test",
            credentialStore: store, transport: transport
        ).client
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
                for: AcceptedMutation(id: Self.operationID),
                client: try client(transport: transport, directory: directory))
            #expect(final.succeeded)
            #expect(transport.recordedRequests.count == 2)
            #expect(transport.recordedRequests.first?.path == "/api/operations/\(Self.operationID)")
        }
    }

    @Test("A successful volume operation decodes through the generated contract")
    func testVolumeOperationDecodes() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(
                    statusCode: 200,
                    json: Self.json(
                        status: "succeeded", resourceKind: "volume", kind: "create"))
            ])
            let waiter = OperationWaiter(pollInterval: 0, timeout: 60, sleeper: { _ in })

            let final = try await waiter.wait(
                for: AcceptedMutation(id: Self.operationID),
                client: try client(transport: transport, directory: directory))
            #expect(final.succeeded)
            #expect(final.resourceKind == .volume)
            #expect(final.kind == .create)
        }
    }

    @Test("A failed operation throws with its error message")
    func testFailure() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 200, json: Self.json(status: "failed", error: "no capacity"))
            ])
            let waiter = OperationWaiter(pollInterval: 0, timeout: 60, sleeper: { _ in })

            do {
                try await waiter.wait(
                    for: AcceptedMutation(id: Self.operationID),
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

    @Test("A lifecycle mutation id is polled from the first pass, with no sleep")
    func testWaitsOnAMutationIdWithNoSeed() async throws {
        // A generation-backed lifecycle mutation answers with the resource and
        // a `mutationId`, not an operation (STR-147), so the waiter must read
        // the operations endpoint straight away rather than sleeping a poll
        // interval first.
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 200, json: Self.json(status: "succeeded"))
            ])
            let slept = SleepCounter()
            let waiter = OperationWaiter(
                pollInterval: 5, timeout: 60, sleeper: { _ in await slept.record() })

            let final = try await waiter.wait(
                for: AcceptedMutation(id: Self.operationID),
                client: try client(transport: transport, directory: directory))
            #expect(final.succeeded)
            #expect(await slept.count == 0)
            #expect(transport.recordedRequests.count == 1)
            #expect(transport.recordedRequests.first?.path == "/api/operations/\(Self.operationID)")
        }
    }

    @Test("Interrupting a wait stops polling without changing the accepted mutation")
    func testInterruptedWait() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 200, json: Self.json(status: "pending")),
                .init(statusCode: 200, json: Self.json(status: "succeeded")),
            ])
            let accepted = AcceptedMutation(id: Self.operationID)
            let api = try client(transport: transport, directory: directory)
            let interrupted = OperationWaiter(
                pollInterval: 0, timeout: 60, sleeper: { _ in throw CancellationError() })

            await #expect(throws: CancellationError.self) {
                try await interrupted.wait(for: accepted, client: api)
            }
            #expect(transport.recordedRequests.count == 1)

            let resumed = OperationWaiter(pollInterval: 0, timeout: 60, sleeper: { _ in })
            let final = try await resumed.wait(for: accepted, client: api)
            #expect(final.succeeded)
            #expect(transport.recordedRequests.count == 2)
            #expect(
                transport.recordedRequests.allSatisfy {
                    $0.request.method == .get && $0.path == "/api/operations/\(Self.operationID)"
                })
        }
    }

    @Test("A lost poll can be resumed using the same mutation id without resubmission")
    func testLostPollResumesObservation() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let disconnected = MockTransport(responses: [])
            let accepted = AcceptedMutation(id: Self.operationID)
            let waiter = OperationWaiter(pollInterval: 0, timeout: 60, sleeper: { _ in })
            await #expect(throws: (any Error).self) {
                try await waiter.wait(
                    for: accepted, client: try client(transport: disconnected, directory: directory))
            }
            #expect(disconnected.recordedRequests.count == 1)

            let reconnected = MockTransport(responses: [
                .init(statusCode: 200, json: Self.json(status: "succeeded"))
            ])
            let final = try await waiter.wait(
                for: accepted, client: try client(transport: reconnected, directory: directory))
            #expect(final.succeeded)
            #expect(reconnected.recordedRequests.count == 1)
            for request in disconnected.recordedRequests + reconnected.recordedRequests {
                #expect(request.request.method == .get)
                #expect(request.path == "/api/operations/\(Self.operationID)")
            }
        }
    }

    @Test("Gives up at the timeout")
    func testTimeout() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [])
            let waiter = OperationWaiter(pollInterval: 0, timeout: 0, sleeper: { _ in })
            await #expect(throws: CLIError.self) {
                try await waiter.wait(
                    for: AcceptedMutation(id: Self.operationID),
                    client: try client(transport: transport, directory: directory))
            }
        }
    }
}
