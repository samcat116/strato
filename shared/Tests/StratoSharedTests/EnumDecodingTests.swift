import Foundation
import Testing
import StratoShared

@Suite("VM status version-skew tolerance")
struct EnumDecodingTests {
    @Test("unrecognized status decodes to .unknown, not an error")
    func vmStatusToleratesUnknownValues() throws {
        #expect(try decodeJSON([VMStatus].self, from: #"["Hibernated"]"#) == [.unknown])
        // Tolerance is case-sensitive: lowercase variants of real states are
        // unrecognized too, and must land on .unknown rather than throw.
        #expect(try decodeJSON([VMStatus].self, from: #"["running"]"#) == [.unknown])
        #expect(try decodeJSON([VMStatus].self, from: #"[""]"#) == [.unknown])
    }
}
