import XCTest
@testable import SwiftSSF
import Foundation

final class SecurityEventTokenTests: XCTestCase {
    
    func testSecurityEventTokenCreation() throws {
        let issuer = URL(string: "https://transmitter.example.com")!
        let events: [String: SecurityEvent] = [:]
        
        let payload = SecurityEventPayload(
            iss: issuer,
            jti: "test-jti-123",
            iat: Int64(Date().timeIntervalSince1970),
            aud: ["test-audience"],
            sub_id: .simple("user@example.com"),
            events: events
        )
        
        let header = JWTHeader(alg: "ES256", typ: "JWT", kid: "test-key-id")
        let token = SecurityEventToken(
            header: header,
            payload: payload,
            rawToken: "test.jwt.token"
        )
        
        XCTAssertEqual(token.header.alg, "ES256")
        XCTAssertEqual(token.payload.iss, issuer)
        XCTAssertEqual(token.payload.jti, "test-jti-123")
        XCTAssertEqual(token.rawToken, "test.jwt.token")
    }
    
    func testSubjectIdentifierSimple() throws {
        let subject = SubjectIdentifier.simple("user@example.com")
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(subject)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SubjectIdentifier.self, from: data)
        
        switch decoded {
        case .simple(let value):
            XCTAssertEqual(value, "user@example.com")
        case .complex:
            XCTFail("Expected simple subject identifier")
        }
    }
    
    func testSubjectIdentifierComplex() throws {
        let complexSubject = ComplexSubjectIdentifier(
            format: "email",
            value: "user@example.com"
        )
        let subject = SubjectIdentifier.complex(complexSubject)
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(subject)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SubjectIdentifier.self, from: data)
        
        switch decoded {
        case .simple:
            XCTFail("Expected complex subject identifier")
        case .complex(let complex):
            XCTAssertEqual(complex.format, "email")
            XCTAssertEqual(complex.value, "user@example.com")
        }
    }
    
    func testAnyCodableEncoding() throws {
        let stringValue = AnyCodable("test")
        let intValue = AnyCodable(42)
        let boolValue = AnyCodable(true)
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        // Test string
        let stringData = try encoder.encode(stringValue)
        let decodedString = try decoder.decode(AnyCodable.self, from: stringData)
        XCTAssertEqual(decodedString.value as? String, "test")
        
        // Test int
        let intData = try encoder.encode(intValue)
        let decodedInt = try decoder.decode(AnyCodable.self, from: intData)
        XCTAssertEqual(decodedInt.value as? Int, 42)
        
        // Test bool
        let boolData = try encoder.encode(boolValue)
        let decodedBool = try decoder.decode(AnyCodable.self, from: boolData)
        XCTAssertEqual(decodedBool.value as? Bool, true)
    }
}