import Foundation
import Testing
import StratoShared

@Suite("Stored guest observation JSON compatibility")
struct StoredObservationJSONCompatibilityTests {
    @Test("Stored observation JSON preserves numeric dates")
    func numericTimestamp() throws {
        let message = GuestAgentObservation(reachable: true, checkedAt: Fixtures.timestamp)
        let data = try encodeJSON(message)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["checkedAt"] is NSNumber)
        let decoded = try JSONDecoder().decode(GuestAgentObservation.self, from: data)
        #expect(decoded.checkedAt.date == Fixtures.timestamp)
        #expect(decoded.reachable)
    }

    @Test("Stored observation JSON accepts ISO-8601 dates")
    func isoTimestamp() throws {
        let json =
            #"{"reachable":true,"checkedAt":"2023-11-14T22:13:20Z"}"#
        let decoded = try decodeJSON(GuestAgentObservation.self, from: json)
        #expect(decoded.checkedAt.date == Fixtures.timestamp)
        #expect(decoded.reachable)
    }

    @Test("Stored observation JSON rejects malformed dates")
    func malformedTimestamp() throws {
        let json = #"{"reachable":true,"checkedAt":"not-a-date"}"#
        #expect(throws: DecodingError.self) { try decodeJSON(GuestAgentObservation.self, from: json) }
    }
}
