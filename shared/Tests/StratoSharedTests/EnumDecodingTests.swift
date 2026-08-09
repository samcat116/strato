import Foundation
import Testing
import StratoShared

@Suite("Enum wire values and version-skew tolerance")
struct EnumDecodingTests {
    // MARK: VMStatus — the one enum with a tolerant fallback

    @Test("unrecognized status decodes to .unknown, not an error")
    func vmStatusToleratesUnknownValues() throws {
        #expect(try decodeJSON([VMStatus].self, from: #"["Hibernated"]"#) == [.unknown])
        // Tolerance is case-sensitive: lowercase variants of real states are
        // unrecognized too, and must land on .unknown rather than throw.
        #expect(try decodeJSON([VMStatus].self, from: #"["running"]"#) == [.unknown])
        #expect(try decodeJSON([VMStatus].self, from: #"[""]"#) == [.unknown])
    }

    // MARK: Enums without a fallback — unknown values are a decode error

    @Test func hypervisorTypeRejectsUnknown() throws {
        // No tolerant fallback: an agent advertising a hypervisor this build
        // doesn't know fails registration decode outright.
        #expect(throws: DecodingError.self) {
            try decodeJSON([HypervisorType].self, from: #"["cloud-hypervisor"]"#)
        }
    }

    @Test func consoleModeRejectsUnknown() throws {
        // Graphics is a separate axis (issue #566), not a console mode: `Vnc`
        // still has no business decoding here.
        #expect(throws: DecodingError.self) {
            try decodeJSON([ConsoleMode].self, from: #"["Vnc"]"#)
        }
    }

    @Test func graphicsModeRejectsUnknown() throws {
        // Strict, like DesiredVMStatus: a mode this build cannot realize must
        // not degrade to "no display" on a VM the API says has one.
        #expect(throws: DecodingError.self) {
            try decodeJSON([GraphicsMode].self, from: #"["Spice"]"#)
        }
        #expect(throws: DecodingError.self) {
            try decodeJSON([GraphicsMode].self, from: #"["vnc"]"#)
        }
    }

    @Test func consoleStreamRejectsUnknown() throws {
        #expect(throws: DecodingError.self) {
            try decodeJSON([ConsoleStream].self, from: #"["Spice"]"#)
        }
    }

    @Test("telemetry enums tolerate unknown values from a newer protocol version")
    func telemetryEnumsTolerateUnknownValues() throws {
        // These are purely informational fields on VMLogMessage; an unrecognized
        // value must decode to .unknown rather than fail the whole log message.
        #expect(try decodeJSON([VMLogLevel].self, from: #"["trace"]"#) == [.unknown])
        #expect(try decodeJSON([VMLogSource].self, from: #"["kernel"]"#) == [.unknown])
        #expect(try decodeJSON([VMEventType].self, from: #"["migration"]"#) == [.unknown])
    }
}
