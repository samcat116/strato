import Testing
import Foundation
@testable import StratoAgentCore

@Suite("NetworkMode Tests")
struct NetworkModeTests {

    @Test("NetworkMode has correct raw values")
    func networkModeRawValues() {
        #expect(NetworkMode.ovn.rawValue == "ovn")
        #expect(NetworkMode.user.rawValue == "user")
    }

    @Test("NetworkMode initializes from raw value")
    func networkModeFromRawValue() {
        #expect(NetworkMode(rawValue: "ovn") == .ovn)
        #expect(NetworkMode(rawValue: "user") == .user)
        #expect(NetworkMode(rawValue: "invalid") == nil)
        #expect(NetworkMode(rawValue: "") == nil)
    }

    @Test("NetworkMode encodes to JSON correctly")
    func networkModeEncoding() throws {
        let encoder = JSONEncoder()

        let ovnData = try encoder.encode(NetworkMode.ovn)
        let ovnString = String(data: ovnData, encoding: .utf8)
        #expect(ovnString == "\"ovn\"")

        let userData = try encoder.encode(NetworkMode.user)
        let userString = String(data: userData, encoding: .utf8)
        #expect(userString == "\"user\"")
    }

    @Test("NetworkMode decodes from JSON correctly")
    func networkModeDecoding() throws {
        let decoder = JSONDecoder()

        let ovnData = "\"ovn\"".data(using: .utf8)!
        let ovnMode = try decoder.decode(NetworkMode.self, from: ovnData)
        #expect(ovnMode == .ovn)

        let userData = "\"user\"".data(using: .utf8)!
        let userMode = try decoder.decode(NetworkMode.self, from: userData)
        #expect(userMode == .user)
    }

    @Test("NetworkMode decoding fails for invalid mode")
    func networkModeDecodingInvalid() throws {
        let decoder = JSONDecoder()
        let invalidData = "\"invalid_mode\"".data(using: .utf8)!

        #expect(throws: Error.self) {
            try decoder.decode(NetworkMode.self, from: invalidData)
        }
    }
}
