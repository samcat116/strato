import Foundation
import Testing
import StratoShared

@Suite("Success / error messages")
struct ResponseMessageTests {
    @Test func successRoundTrip() throws {
        let payload = try AnyCodableValue(["state": "Running"])
        let decoded = try throughEnvelope(
            SuccessMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                message: "done",
                data: payload
            )
        )
        #expect(decoded.type == .success)
        #expect(decoded.message == "done")
        #expect(try decoded.data?.decode(as: [String: String].self) == ["state": "Running"])
    }

    @Test func successWithTypedDataRoundTrip() throws {
        // The real handlers ship typed structs through AnyCodableValue —
        // e.g. VolumeStatusResponse inside a SuccessMessage.
        let status = VolumeStatusResponse(
            volumeId: "vol-1", status: "attached", storagePath: "/var/lib/strato/vol-1.qcow2")
        let message = SuccessMessage(requestId: Fixtures.requestId, data: try AnyCodableValue(status))
        let decoded = try throughEnvelope(message)
        let extracted = try #require(try decoded.data?.decode(as: VolumeStatusResponse.self))
        #expect(extracted.volumeId == "vol-1")
        #expect(extracted.status == "attached")
        #expect(extracted.storagePath == "/var/lib/strato/vol-1.qcow2")
    }

    @Test func errorRoundTrip() throws {
        let decoded = try throughEnvelope(
            ErrorMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                error: "boot failed",
                details: "qemu exited with status 1",
                code: ErrorMessage.ErrorCode.invalidToken
            )
        )
        #expect(decoded.type == .error)
        #expect(decoded.error == "boot failed")
        #expect(decoded.details == "qemu exited with status 1")
        #expect(decoded.code == "invalid_token")
    }

    /// `code` is documented as optional so peers that predate error
    /// classification still interoperate; absence must decode as nil.
    @Test func errorDecodesWithoutCode() throws {
        let json = """
            {"requestId":"r","timestamp":0,"error":"nope"}
            """
        let decoded = try decodeJSON(ErrorMessage.self, from: json)
        #expect(decoded.error == "nope")
        #expect(decoded.details == nil)
        #expect(decoded.code == nil)
    }

    @Test func vmLogRoundTrip() throws {
        let decoded = try throughEnvelope(
            VMLogMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                vmId: "vm-8",
                level: .warning,
                source: .qemu,
                eventType: .statusChange,
                message: "guest reset",
                operation: "reboot",
                details: "triple fault",
                previousStatus: .running,
                newStatus: .starting
            )
        )
        #expect(decoded.type == .vmLog)
        #expect(decoded.vmId == "vm-8")
        #expect(decoded.level == .warning)
        #expect(decoded.source == .qemu)
        #expect(decoded.eventType == .statusChange)
        #expect(decoded.message == "guest reset")
        #expect(decoded.operation == "reboot")
        #expect(decoded.details == "triple fault")
        #expect(decoded.previousStatus == .running)
        #expect(decoded.newStatus == .starting)
    }
}
