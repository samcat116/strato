import Foundation
import Testing
import StratoShared

@Suite("AnyCodableValue / CodableValue dynamic payloads")
struct CodableValueTests {
    @Test func stringRoundTrip() throws {
        let value = try AnyCodableValue("hello")
        #expect(try roundTrip(value).decode(as: String.self) == "hello")
    }

    @Test func intRoundTrip() throws {
        let value = try AnyCodableValue(42)
        #expect(try roundTrip(value).decode(as: Int.self) == 42)
    }

    @Test func doubleRoundTrip() throws {
        let value = try AnyCodableValue(3.25)
        #expect(try roundTrip(value).decode(as: Double.self) == 3.25)
    }

    @Test func boolRoundTrip() throws {
        let value = try AnyCodableValue(true)
        #expect(try roundTrip(value).decode(as: Bool.self) == true)
    }

    @Test func nullDecodesAsNullCase() throws {
        let decoded = try decodeJSON(CodableValue.self, from: "null")
        guard case .null = decoded else {
            Issue.record("expected .null, got \(decoded)")
            return
        }
    }

    @Test func arrayRoundTrip() throws {
        let value = try AnyCodableValue(["a", "b", "c"])
        #expect(try roundTrip(value).decode(as: [String].self) == ["a", "b", "c"])
    }

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
        let decoded = try roundTrip(AnyCodableValue(payload)).decode(as: Payload.self)
        #expect(decoded == payload)
    }

    @Test func heterogeneousObjectSurvivesEnvelope() throws {
        // The typical shape of SuccessMessage.data: an untyped bag of values.
        let json = """
            {"state":"Running","cpus":4,"balloon":0.5,"paused":false,
             "tags":["web","prod"],"nested":{"depth":2},"missing":null}
            """
        let value = try decodeJSON(CodableValue.self, from: json)
        let reencoded = try roundTrip(value)

        guard case .object(let object) = reencoded else {
            Issue.record("expected .object, got \(reencoded)")
            return
        }
        guard case .string(let state)? = object["state"] else {
            Issue.record("state lost"); return
        }
        #expect(state == "Running")
        guard case .int(let cpus)? = object["cpus"] else {
            Issue.record("cpus lost"); return
        }
        #expect(cpus == 4)
        guard case .double(let balloon)? = object["balloon"] else {
            Issue.record("balloon lost"); return
        }
        #expect(balloon == 0.5)
        guard case .bool(let paused)? = object["paused"] else {
            Issue.record("paused lost"); return
        }
        #expect(paused == false)
        guard case .array(let tags)? = object["tags"] else {
            Issue.record("tags lost"); return
        }
        #expect(tags.count == 2)
        guard case .object(let nested)? = object["nested"] else {
            Issue.record("nested lost"); return
        }
        guard case .int(let depth)? = nested["depth"] else {
            Issue.record("depth lost"); return
        }
        #expect(depth == 2)
        guard case .null? = object["missing"] else {
            Issue.record("null lost"); return
        }
    }
}
