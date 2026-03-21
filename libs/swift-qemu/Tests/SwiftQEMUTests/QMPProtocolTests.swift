import XCTest
@testable import SwiftQEMU

final class QMPProtocolTests: XCTestCase {
    
    func testQMPGreetingDecoding() throws {
        let json = """
        {
            "QMP": {
                "version": {
                    "qemu": {"micro": 0, "minor": 0, "major": 7},
                    "package": ""
                },
                "capabilities": []
            }
        }
        """
        
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        
        let greeting = try decoder.decode(QMPGreeting.self, from: data)
        
        XCTAssertEqual(greeting.QMP.version.qemu.major, 7)
        XCTAssertEqual(greeting.QMP.version.qemu.minor, 0)
        XCTAssertEqual(greeting.QMP.version.qemu.micro, 0)
        XCTAssertEqual(greeting.QMP.capabilities.count, 0)
    }
    
    func testQMPRequestEncoding() throws {
        let request = QMPRequest(
            execute: "query-status",
            arguments: nil,
            id: AnyCodable(1)
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        
        let data = try encoder.encode(request)
        let json = String(data: data, encoding: .utf8)!
        
        XCTAssertTrue(json.contains("\"execute\":\"query-status\""))
        XCTAssertTrue(json.contains("\"id\":1"))
    }
    
    func testQMPResponseDecoding() throws {
        let json = """
        {
            "return": {
                "status": "running",
                "singlestep": false,
                "running": true
            },
            "id": 1
        }
        """
        
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        
        let response = try decoder.decode(QMPResponse.self, from: data)
        
        XCTAssertNotNil(response.return)
        XCTAssertNil(response.error)
        
        if let returnValue = response.return?.value as? [String: Any] {
            XCTAssertEqual(returnValue["status"] as? String, "running")
            XCTAssertEqual(returnValue["running"] as? Bool, true)
            XCTAssertEqual(returnValue["singlestep"] as? Bool, false)
        } else {
            XCTFail("Failed to decode return value")
        }
    }
    
    func testQMPErrorResponseDecoding() throws {
        let json = """
        {
            "error": {
                "class": "CommandNotFound",
                "desc": "The command invalid-command has not been found"
            },
            "id": 1
        }
        """
        
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        
        let response = try decoder.decode(QMPResponse.self, from: data)
        
        XCTAssertNil(response.return)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(response.error?.class, "CommandNotFound")
        XCTAssertTrue(response.error?.desc.contains("invalid-command") ?? false)
    }
    
    func testAnyCodableEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        
        // Test various types
        let intValue = AnyCodable(42)
        let stringValue = AnyCodable("test")
        let boolValue = AnyCodable(true)
        let dictValue = AnyCodable(["key": "value", "number": 123])
        
        let intData = try encoder.encode(intValue)
        let stringData = try encoder.encode(stringValue)
        let boolData = try encoder.encode(boolValue)
        let dictData = try encoder.encode(dictValue)
        
        XCTAssertEqual(String(data: intData, encoding: .utf8), "42")
        XCTAssertEqual(String(data: stringData, encoding: .utf8), "\"test\"")
        XCTAssertEqual(String(data: boolData, encoding: .utf8), "true")
        
        let dictJson = String(data: dictData, encoding: .utf8)!
        XCTAssertTrue(dictJson.contains("\"key\":\"value\""))
        XCTAssertTrue(dictJson.contains("\"number\":123"))
    }
}