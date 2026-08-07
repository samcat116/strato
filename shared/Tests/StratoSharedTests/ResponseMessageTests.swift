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
        // `SuccessMessage.data` carries an arbitrary `Codable` through
        // `AnyCodableValue`, and this pins that mechanism rather than any one
        // payload: every typed reply that used to ride it is gone —
        // `VolumeStatusResponse` and the two snapshot reports with wire v33
        // (STR-150), `VolumeInfoResponse` with v32 (STR-149) — because the
        // facts they carried are desired/observed state now. The remaining
        // senders answer with a bare success, so a live wire struct stands in.
        let guest = GuestInfo(
            qgaAvailable: true, hostname: "guest-1",
            interfaces: [
                GuestNetworkInterface(
                    name: "eth0", hardwareAddress: "52:54:00:ab:cd:ef",
                    addresses: [GuestIPAddress(family: .ipv4, address: "10.0.0.5")])
            ])
        let message = SuccessMessage(requestId: Fixtures.requestId, data: try AnyCodableValue(guest))
        let decoded = try throughEnvelope(message)
        let extracted = try #require(try decoded.data?.decode(as: GuestInfo.self))
        #expect(extracted.hostname == "guest-1")
        #expect(extracted.interfaces.first?.addresses.first?.address == "10.0.0.5")
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
