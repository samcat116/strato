import Foundation
import Testing

@testable import App

@Suite("Operation response contract")
struct OperationResponseContractTests {
    @Test("The legacy VM id remains emitted but is optional when decoding")
    func legacyVMIDDeprecationCycle() throws {
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
        #expect(encoded["vmId"] as? String == resourceID.uuidString)

        let withoutLegacyField = """
            {"resourceKind":"virtual_machine","resourceId":"\(resourceID)","kind":"boot","status":"pending"}
            """
        let decoded = try JSONDecoder().decode(
            OperationResponse.self, from: Data(withoutLegacyField.utf8))
        #expect(decoded.vmId == nil)
        #expect(decoded.resourceId == resourceID)
    }
}
