import XCTest
import Foundation
@testable import StratoAgentCore

final class NetworkModeTests: XCTestCase {

    // MARK: - NetworkMode Enum Tests

    func testNetworkModeRawValues() {
        XCTAssertEqual(NetworkMode.ovn.rawValue, "ovn")
        XCTAssertEqual(NetworkMode.user.rawValue, "user")
    }

    func testNetworkModeFromRawValue() {
        XCTAssertEqual(NetworkMode(rawValue: "ovn"), .ovn)
        XCTAssertEqual(NetworkMode(rawValue: "user"), .user)
        XCTAssertNil(NetworkMode(rawValue: "invalid"))
        XCTAssertNil(NetworkMode(rawValue: ""))
    }

    func testNetworkModeEncoding() throws {
        let encoder = JSONEncoder()

        let ovnData = try encoder.encode(NetworkMode.ovn)
        let ovnString = String(data: ovnData, encoding: .utf8)
        XCTAssertEqual(ovnString, "\"ovn\"")

        let userData = try encoder.encode(NetworkMode.user)
        let userString = String(data: userData, encoding: .utf8)
        XCTAssertEqual(userString, "\"user\"")
    }

    func testNetworkModeDecoding() throws {
        let decoder = JSONDecoder()

        let ovnData = "\"ovn\"".data(using: .utf8)!
        let ovnMode = try decoder.decode(NetworkMode.self, from: ovnData)
        XCTAssertEqual(ovnMode, .ovn)

        let userData = "\"user\"".data(using: .utf8)!
        let userMode = try decoder.decode(NetworkMode.self, from: userData)
        XCTAssertEqual(userMode, .user)
    }

    func testNetworkModeDecodingInvalid() {
        let decoder = JSONDecoder()

        let invalidData = "\"invalid_mode\"".data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(NetworkMode.self, from: invalidData))
    }
}
