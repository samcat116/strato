import XCTest
@testable import SwiftSSF

final class SwiftSSFTests: XCTestCase {
    
    func testFrameworkConstants() throws {
        XCTAssertEqual(swiftSSFVersion, "1.0.0")
        XCTAssertEqual(supportedSSFVersion, "1.0")
        
        XCTAssertTrue(supportedEventTypes.contains("https://schemas.openid.net/secevent/caep/session-revoked"))
        XCTAssertTrue(supportedEventTypes.contains("https://schemas.openid.net/secevent/risc/account-disabled"))
        
        XCTAssertTrue(supportedDeliveryMethods.contains("urn:ietf:rfc:8935"))
        XCTAssertTrue(supportedDeliveryMethods.contains("urn:ietf:rfc:8936"))
    }
    
    func testSSFReceiverConfiguration() throws {
        let transmitterURL = URL(string: "https://transmitter.example.com")!
        
        let config = SSFReceiverConfiguration(
            transmitterURL: transmitterURL,
            authToken: "test-token",
            expectedAudience: ["test-receiver"],
            autoFetchJWKS: true
        )
        
        XCTAssertEqual(config.transmitterURL, transmitterURL)
        XCTAssertEqual(config.authToken, "test-token")
        XCTAssertEqual(config.expectedAudience, ["test-receiver"])
        XCTAssertEqual(config.expectedIssuer, transmitterURL)
        XCTAssertTrue(config.autoFetchJWKS)
    }
    
    func testSSFErrorTypes() throws {
        let networkError = SSFError.networkError(URLError(.notConnectedToInternet))
        let httpError = SSFError.httpError(statusCode: 404, message: "Not Found")
        let authError = SSFError.authenticationFailed("Invalid token")
        
        XCTAssertNotNil(networkError.errorDescription)
        XCTAssertNotNil(httpError.errorDescription)
        XCTAssertNotNil(authError.errorDescription)
        
        XCTAssertTrue(httpError.errorDescription!.contains("404"))
        XCTAssertTrue(authError.errorDescription!.contains("Invalid token"))
    }
    
    func testSSFErrorCodes() throws {
        let errorCodes = SSFErrorCode.allCases
        
        XCTAssertTrue(errorCodes.contains(.invalidRequest))
        XCTAssertTrue(errorCodes.contains(.unauthorized))
        XCTAssertTrue(errorCodes.contains(.streamNotFound))
        XCTAssertTrue(errorCodes.contains(.verificationFailed))
        
        XCTAssertEqual(SSFErrorCode.invalidRequest.rawValue, "invalid_request")
        XCTAssertEqual(SSFErrorCode.streamNotFound.rawValue, "stream_not_found")
    }
    
    func testLogginEventHandler() async throws {
        let handler = LoggingEventHandler()
        
        // Create a test security event token
        let issuer = URL(string: "https://test.example.com")!
        let payload = SecurityEventPayload(
            iss: issuer,
            jti: "test-jti",
            iat: Int64(Date().timeIntervalSince1970),
            aud: ["test-audience"],
            sub_id: .simple("test@example.com"),
            events: [:]
        )
        
        let header = JWTHeader(alg: "ES256", typ: "JWT")
        let token = SecurityEventToken(
            header: header,
            payload: payload,
            rawToken: "test.jwt.token"
        )
        
        // Test that handler doesn't throw
        try await handler.handleEvent(token)
        
        // Test error handling
        let error = SSFError.signatureVerificationFailed
        await handler.handleError(error, token: token)
    }
}
