import XCTest
@testable import SwiftSSF
import Foundation
import Crypto

final class JWTProcessorTests: XCTestCase {
    
    func testJWTParsingWithoutValidation() async throws {
        let processor = JWTProcessor()
        
        // Create a simple JWT for testing (header.payload.signature)
        let header = """
        {"alg":"ES256","typ":"JWT","kid":"test-key"}
        """
        let payload = """
        {"iss":"https://example.com","jti":"test-123","iat":1234567890,"aud":["test"],"events":{}}
        """
        
        let headerB64 = Data(header.utf8).base64URLEncodedString()
        let payloadB64 = Data(payload.utf8).base64URLEncodedString()
        let signatureB64 = "fake-signature"
        
        let jwt = "\(headerB64).\(payloadB64).\(signatureB64)"
        
        let (parsedHeader, parsedPayload) = try await processor.parseJWT(jwt)
        
        XCTAssertEqual(parsedHeader.alg, "ES256")
        XCTAssertEqual(parsedHeader.typ, "JWT")
        XCTAssertEqual(parsedHeader.kid, "test-key")
        
        XCTAssertEqual(parsedPayload["iss"] as? String, "https://example.com")
        XCTAssertEqual(parsedPayload["jti"] as? String, "test-123")
        XCTAssertEqual(parsedPayload["iat"] as? Int, 1234567890)
    }
    
    func testInvalidJWTFormat() async throws {
        let processor = JWTProcessor()
        
        // Test invalid JWT with wrong number of parts
        do {
            _ = try await processor.parseJWT("invalid.jwt")
            XCTFail("Should have thrown an error for invalid JWT format")
        } catch SSFError.invalidJWT(let message) {
            XCTAssertTrue(message.contains("exactly 3 parts"))
        }
    }
    
    func testCreateSecurityEventToken() async throws {
        let processor = JWTProcessor()
        let privateKey = P256.Signing.PrivateKey()
        
        let issuer = URL(string: "https://transmitter.example.com")!
        let audience = ["test-receiver"]
        let events: [String: SecurityEvent] = [:]
        
        let token = try await processor.createSecurityEventToken(
            issuer: issuer,
            audience: audience,
            events: events,
            privateKey: privateKey
        )
        
        XCTAssertEqual(token.header.alg, "ES256")
        XCTAssertEqual(token.payload.iss, issuer)
        XCTAssertEqual(token.payload.aud, audience)
        XCTAssertNotNil(token.payload.jti)
    }
    
    func testSecurityEventTokenValidation() async throws {
        let processor = JWTProcessor()
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let issuer = URL(string: "https://transmitter.example.com")!
        let audience = ["test-receiver"]
        let events: [String: SecurityEvent] = [:]
        
        // Create a token
        let token = try await processor.createSecurityEventToken(
            issuer: issuer,
            audience: audience,
            events: events,
            privateKey: privateKey
        )
        
        // Validate the token
        let validatedToken = try await processor.parseSecurityEventToken(
            token.rawToken,
            expectedIssuer: issuer,
            expectedAudience: audience,
            publicKey: publicKey
        )
        
        XCTAssertEqual(validatedToken.payload.iss, issuer)
        XCTAssertEqual(validatedToken.payload.aud, audience)
    }
    
    func testSignatureVerificationFailure() async throws {
        let processor = JWTProcessor()
        let privateKey = P256.Signing.PrivateKey()
        let wrongPublicKey = P256.Signing.PrivateKey().publicKey // Different key
        
        let issuer = URL(string: "https://transmitter.example.com")!
        let audience = ["test-receiver"]
        let events: [String: SecurityEvent] = [:]
        
        // Create a token with one key
        let token = try await processor.createSecurityEventToken(
            issuer: issuer,
            audience: audience,
            events: events,
            privateKey: privateKey
        )
        
        // Try to validate with wrong key
        do {
            _ = try await processor.parseSecurityEventToken(
                token.rawToken,
                expectedIssuer: issuer,
                expectedAudience: audience,
                publicKey: wrongPublicKey
            )
            XCTFail("Should have thrown signature verification error")
        } catch SSFError.signatureVerificationFailed {
            // Expected error
        }
    }
    
    func testIssuerValidation() async throws {
        let processor = JWTProcessor()
        let privateKey = P256.Signing.PrivateKey()
        
        let issuer = URL(string: "https://transmitter.example.com")!
        let wrongIssuer = URL(string: "https://wrong.example.com")!
        let audience = ["test-receiver"]
        let events: [String: SecurityEvent] = [:]
        
        // Create a token
        let token = try await processor.createSecurityEventToken(
            issuer: issuer,
            audience: audience,
            events: events,
            privateKey: privateKey
        )
        
        // Try to validate with wrong issuer
        do {
            _ = try await processor.parseSecurityEventToken(
                token.rawToken,
                expectedIssuer: wrongIssuer,
                expectedAudience: audience,
                publicKey: privateKey.publicKey
            )
            XCTFail("Should have thrown invalid issuer error")
        } catch SSFError.invalidIssuer {
            // Expected error
        }
    }
    
    func testAudienceValidation() async throws {
        let processor = JWTProcessor()
        let privateKey = P256.Signing.PrivateKey()
        
        let issuer = URL(string: "https://transmitter.example.com")!
        let audience = ["test-receiver"]
        let wrongAudience = ["wrong-receiver"]
        let events: [String: SecurityEvent] = [:]
        
        // Create a token
        let token = try await processor.createSecurityEventToken(
            issuer: issuer,
            audience: audience,
            events: events,
            privateKey: privateKey
        )
        
        // Try to validate with wrong audience
        do {
            _ = try await processor.parseSecurityEventToken(
                token.rawToken,
                expectedIssuer: issuer,
                expectedAudience: wrongAudience,
                publicKey: privateKey.publicKey
            )
            XCTFail("Should have thrown invalid audience error")
        } catch SSFError.invalidAudience {
            // Expected error
        }
    }
}

// MARK: - Base64URL Extension Tests

extension Data {
    /// Initialize from base64url encoded string
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        
        self.init(base64Encoded: base64)
    }
    
    /// Encode as base64url string
    func base64URLEncodedString() -> String {
        return base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}