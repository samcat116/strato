import Foundation
import Testing

@testable import App

@Suite("Operation response contract")
struct OperationResponseContractTests {
    @Test("The operation target uses only the kind-aware resource fields")
    func operationTargetContract() throws {
        let resourceID = UUID()
        let response = OperationResponse(
            id: UUID(),
            resourceKind: .sandbox,
            resourceID: resourceID,
            kind: .create,
            status: .pending,
            error: nil,
            createdAt: nil,
            completedAt: nil
        )

        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        #expect(!encoded.keys.contains("vmId"))
        #expect(encoded["resourceKind"] as? String == "sandbox")
        #expect(encoded["resourceId"] as? String == resourceID.uuidString)

        let operation = """
            {"resourceKind":"virtual_machine","resourceId":"\(resourceID)","kind":"boot","status":"pending"}
            """
        let decoded = try JSONDecoder().decode(
            OperationResponse.self, from: Data(operation.utf8))
        #expect(decoded.resourceKind == .virtualMachine)
        #expect(decoded.resourceId == resourceID)
    }

    @Test("A captured command result carries separate streams and exit status")
    func commandResultContract() throws {
        let response = OperationResponse(
            id: UUID(), resourceKind: .virtualMachine, resourceID: UUID(), kind: .run,
            status: .succeeded, error: nil, createdAt: nil, completedAt: Date(),
            result: VMCommandResultResponse(
                stdout: "out", stderr: "err", exitCode: 23, truncated: true))

        let encoded = try JSONEncoder().encode(response)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        #expect(object["kind"] as? String == "run")
        #expect(result["stdout"] as? String == "out")
        #expect(result["stderr"] as? String == "err")
        #expect(result["exitCode"] as? Int == 23)
        #expect(result["truncated"] as? Bool == true)
    }
}
