import Testing
import StratoShared

@Suite("VM action messages")
struct VMMessageTests {
    @Test func vmRebootRoundTrip() throws {
        let message = VMOperationMessage(
            type: .vmReboot,
            requestId: Fixtures.requestId,
            timestamp: Fixtures.timestamp,
            vmId: "vm-9"
        )
        let decoded = try throughEnvelope(message)
        #expect(decoded.type == .vmReboot)
        #expect(decoded.vmId == "vm-9")
        #expect(decoded.requestId == Fixtures.requestId)
    }
}
