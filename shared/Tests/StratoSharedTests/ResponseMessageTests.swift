import Foundation
import Testing
import StratoShared

@Suite("Success / error messages")
struct ResponseMessageTests {
    @Test func successRoundTrip() throws {
        let decoded = try throughEnvelope(
            SuccessMessage(
                requestId: Fixtures.requestId,
                timestamp: Fixtures.timestamp,
                message: "done"
            )
        )
        #expect(decoded.type == .success)
        #expect(decoded.requestId == Fixtures.requestId)
        #expect(decoded.message == "done")
    }

    /// `SuccessMessage.data` carried an arbitrary `Codable` through
    /// `AnyCodableValue` until STR-152 removed it: every typed reply that rode
    /// it was already gone — `VolumeStatusResponse` and the two snapshot
    /// reports with wire v33 (STR-150), `VolumeInfoResponse` with v32
    /// (STR-149) — because the facts they carried are desired/observed state
    /// now, and the correlation that would have awaited one went with them.
    /// A peer still sending the key must decode as an ordinary success rather
    /// than failing, which is what keeps the removal compatible in both
    /// directions and needing no wire-version bump.
    @Test func successIgnoresLegacyDataField() throws {
        let json = """
            {"requestId":"r","timestamp":0,"message":"done","data":{"state":"Running"}}
            """
        let decoded = try decodeJSON(SuccessMessage.self, from: json)
        #expect(decoded.requestId == "r")
        #expect(decoded.message == "done")
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
                source: .agent,
                eventType: .statusChange,
                message: "guest reset",
                operation: "reboot"
            )
        )
        #expect(decoded.type == .vmLog)
        #expect(decoded.vmId == "vm-8")
        #expect(decoded.level == .warning)
        #expect(decoded.source == .agent)
        #expect(decoded.eventType == .statusChange)
        #expect(decoded.message == "guest reset")
        #expect(decoded.operation == "reboot")
    }
}
