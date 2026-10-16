import Foundation
import Testing
@testable import StratoShared

@Suite("Guest config observation boundary")
struct GuestConfigObservationTests {
    @Test func terminalGuestFailureRoundTripsWithoutInventingReadBack() throws {
        let id = UUID()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let observed = ObservedVMState(
            vmId: id, status: .running, observedGeneration: 6,
            lastError: "channel unavailable", failedGeneration: 7, failureClassification: .permanent,
            guestConfigFailedGeneration: 7)
        let report = try decoder.decode(ObservedVMState.self, from: encoder.encode(observed))
        #expect(report.guestConfigFailedGeneration == 7)
        #expect(report.guestConfigObservation == nil)
        let desired = DesiredVMState(
            vmId: id, hypervisorType: .qemu,
            spec: VMSpec(cpus: 1, memoryBytes: 1 << 30, boot: .disk(firmware: nil)),
            desiredStatus: .running, generation: 7, guestConfigFailedGeneration: 7)
        let data = try encoder.encode(desired)
        #expect(try decoder.decode(DesiredVMState.self, from: data).guestConfigFailedGeneration == 7)
        var stored = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        stored.removeValue(forKey: "guestConfigFailedGeneration")
        #expect(
            try decoder.decode(DesiredVMState.self, from: JSONSerialization.data(withJSONObject: stored))
                .guestConfigFailedGeneration == nil)
    }

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

    @Test func successfulFilesRequireMatchingLocallyComputedDigests() throws {
        let config = GuestConfig(files: [GuestFile(path: "/etc/example", content: "hello\n", mode: "0644")])
        let expected = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
        for digest in [expected, String(repeating: "0", count: 64)] {
            let json = """
                {"generation":7,"status":"converged","packages":[],"files":[{"path":"/etc/example","sha256":"\(digest)","mode":"0644"}],"services":[],"sysctls":[]}
                """
            let observation = try JSONDecoder().decode(GuestConfigObservation.self, from: Data(json.utf8))
            #expect(throws: GuestConfigObservationError.self) {
                try observation.validate(for: config, generation: 7)
            }
            if digest == expected {
                try observation.validate(for: config, generation: 7, expectedFileSHA256: ["/etc/example": expected])
            } else {
                #expect(throws: GuestConfigObservationError.self) {
                    try observation.validate(for: config, generation: 7, expectedFileSHA256: ["/etc/example": expected])
                }
            }
        }
    }

    @Test func failedFileObservationsCanRetainTheMismatchedDigest() throws {
        let config = GuestConfig(files: [GuestFile(path: "/etc/example", content: "hello\n", mode: "0644")])
        let json = """
            {"generation":7,"status":"failed","error":"file read-back differs from desired state","packages":[],"files":[{"path":"/etc/example","sha256":"\(String(repeating: "0", count: 64))","mode":"0644"}],"services":[],"sysctls":[]}
            """
        let observation = try JSONDecoder().decode(GuestConfigObservation.self, from: Data(json.utf8))
        try observation.validate(for: config, generation: 7)
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
