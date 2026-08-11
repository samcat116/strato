import Foundation
import Testing

@testable import StratoShared

@Suite("JSONValue Tests")
struct JSONValueTests {
    @Test("Preserves unknown, null, and mixed JSON values through Codable")
    func roundTripsEveryJSONKind() throws {
        let input = Data(
            #"{"known":"value","unknown":{"nested":true},"items":[null,1,2.5,"three",false]}"#.utf8)

        let decoded = try JSONDecoder().decode(JSONValue.self, from: input)
        #expect(decoded["known"]?.stringValue == "value")
        #expect(decoded["unknown"]?["nested"] == .bool(true))
        #expect(decoded["items"]?.arrayValue?.first == .null)

        let encoded = try JSONEncoder().encode(decoded)
        #expect(try JSONDecoder().decode(JSONValue.self, from: encoded) == decoded)
    }

    @Test("Rejects malformed JSON")
    func rejectsMalformedJSON() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(JSONValue.self, from: Data(#"{"unterminated":true"#.utf8))
        }
    }
}
