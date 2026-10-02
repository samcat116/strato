import Foundation
import Testing
@testable import StratoShared

@Suite("Guest config observation boundary")
struct GuestConfigObservationTests {
    private func decode(_ facts: String, status: String = "converged", error: String = "null") throws
        -> GuestConfigObservation
    {
        let json = """
            {"generation":7,"status":"\(status)","error":\(error),"packages":\(facts),"files":[],"services":[],"sysctls":[]}
            """
        return try JSONDecoder().decode(GuestConfigObservation.self, from: Data(json.utf8))
    }
    @Test func rejectsForeignDuplicateIncompleteAndOversizedFacts() throws {
        let config = GuestConfig(packages: [GuestPackage(name: "curl", state: .present)])
        for facts in [
            "[]", #"[{"name":"other","version":"1"}]"#,
            #"[{"name":"curl","version":"1"},{"name":"curl","version":"1"}]"#,
            "[{\"name\":\"curl\",\"version\":\"\(String(repeating: "x", count: 256))\"}]",
        ] {
            let observation = try decode(facts)
            #expect(throws: GuestConfigObservationError.self) { try observation.validate(for: config, generation: 7) }
        }
        let valid = try decode(#"[{"name":"curl","version":"1.2"}]"#)
        try valid.validate(for: config, generation: 7)
        #expect(throws: GuestConfigObservationError.self) { try valid.validate(for: config, generation: 6) }
    }
    @Test func failureCanCarryPartialFactsButCannotAlsoClaimSuccess() throws {
        let config = GuestConfig(packages: [GuestPackage(name: "curl", state: .present)])
        try decode("[]", status: "failed", error: #""package operation budget exhausted""#).validate(
            for: config, generation: 7)
        let missingError = try decode("[]", status: "failed")
        #expect(throws: GuestConfigObservationError.self) { try missingError.validate(for: config, generation: 7) }
        let successError = try decode(#"[{"name":"curl","version":"1"}]"#, error: #""failed""#)
        #expect(throws: GuestConfigObservationError.self) { try successError.validate(for: config, generation: 7) }
    }

    @Test func itemFailureIdentifiesOnlyAManagedRowAndMatchesTheFailureReason() throws {
        let config = GuestConfig(packages: [GuestPackage(name: "curl", state: .present)])
        for identity in ["curl", "foreign"] {
            let json = """
                {"generation":7,"status":"failed","error":"package budget exhausted","failedItem":{"section":"packages","identity":"\(identity)","reason":"package budget exhausted"},"packages":[],"files":[],"services":[],"sysctls":[]}
                """
            let observation = try JSONDecoder().decode(GuestConfigObservation.self, from: Data(json.utf8))
            if identity == "curl" {
                try observation.validate(for: config, generation: 7)
            } else {
                #expect(throws: GuestConfigObservationError.self) {
                    try observation.validate(for: config, generation: 7)
                }
            }
        }
    }

}
