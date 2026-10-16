import Foundation
import Testing
import StratoShared

@Suite("JSONValue dynamic payloads")
struct JSONValueDynamicPayloadTests {
    @Test func nestedObjectRoundTrip() throws {
        struct Payload: Codable, Equatable {
            struct Inner: Codable, Equatable {
                let name: String
                let count: Int
                let enabled: Bool
            }
            let items: [Inner]
            let note: String?
        }
        let payload = Payload(
            items: [
                Payload.Inner(name: "first", count: 1, enabled: true),
                Payload.Inner(name: "second", count: 2, enabled: false),
            ],
            note: nil
        )
        let encoded = try WireProtocol.makeEncoder().encode(payload)
        let value = try WireProtocol.makeDecoder().decode(JSONValue.self, from: encoded)
        let decoded = try roundTrip(value).decode(as: Payload.self)
        #expect(decoded == payload)
    }

}
