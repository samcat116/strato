import Testing

@testable import StratoCLICore

@Suite("Volume block-mode CLI parsing")
struct VolumeBlockModeParserTests {
    @Test("API and readable shared-cache spellings map to the stable wire value")
    func acceptedValues() throws {
        #expect(try parseVolumeBlockMode(nil) == nil)
        #expect(try parseVolumeBlockMode("conservative")?.rawValue == "conservative")
        #expect(try parseVolumeBlockMode("direct")?.rawValue == "direct")
        #expect(try parseVolumeBlockMode("cachedShared")?.rawValue == "cachedShared")
        #expect(try parseVolumeBlockMode("cached-shared")?.rawValue == "cachedShared")
    }

    @Test("Unknown modes fail before sending a request")
    func rejectedValue() {
        #expect(throws: CLIError.self) {
            try parseVolumeBlockMode("unsafe")
        }
    }
}
