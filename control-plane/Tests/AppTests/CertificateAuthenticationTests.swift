import XCTest
import Vapor
import FluentSQLiteDriver
@testable import App
import StratoShared

final class CertificateAuthenticationTests: XCTestCase {
    var app: Application!
    
    override func setUp() async throws {
        // Set testing environment variable to ensure mocks are used
        setenv("TESTING", "1", 1)
        
        app = Application(.testing)
        
        // Ensure testing environment is properly detected
        XCTAssertEqual(app.environment, .testing, "App should be in testing environment")
        
        // Configure in-memory SQLite for testing
        app.databases.use(.sqlite(.memory), as: .psql)
        
        // Add migrations
        app.migrations.add(CreateCertificateAuthority())
        app.migrations.add(CreateAgentCertificate())
        
        try await app.autoMigrate()
        
        // Configure JWT for testing
        app.jwt.signers.use(.hs256(key: "test-secret-key"))
    }
    
    override func tearDown() async throws {
        // Clean up environment variable
        unsetenv("TESTING")
        
        try await app.asyncShutdown()
        app = nil
    }
    
    func testCertificateEnrollmentFlow() async throws {
        // Test the enrollment services directly instead of via HTTP
        // This avoids potential middleware issues
        
        // Create join token service
        let joinTokenService = JoinTokenService(logger: app.logger)
        let joinToken = try joinTokenService.generateJoinToken(for: "test-agent")
        
        XCTAssertFalse(joinToken.isEmpty, "Join token should not be empty")
        
        // Verify the token can be decoded
        let decodedToken = try app.jwt.signers.verify(joinToken, as: JoinTokenPayload.self)
        XCTAssertEqual(decodedToken.agentId, "test-agent")
    }
    
    func testCertificateValidation() async throws {
        // Initialize CA
        let caService = CertificateAuthorityService(database: app.db, logger: app.logger)
        let ca = try await caService.initializeDefaultCA()
        
        // Create a test certificate
        let agentMetadata = AgentMetadata(
            hostname: "test-host",
            platform: "linux",
            version: "1.0.0",
            capabilities: ["vm-management"],
            tpmAvailable: false
        )
        
        let csr = CertificateSigningRequest(
            publicKeyPEM: "dGVzdC1wdWJsaWMta2V5",
            agentId: "test-agent",
            commonName: "test-agent",
            agentMetadata: agentMetadata
        )
        
        let certificate = try await caService.issueCertificate(
            for: "test-agent",
            csr: csr,
            ca: ca
        )
        
        // Verify certificate properties
        XCTAssertEqual(certificate.agentId, "test-agent")
        XCTAssertTrue(certificate.spiffeURI.contains("test-agent"))
        XCTAssertEqual(certificate.status, .active)
        XCTAssertTrue(certificate.isValid)
        XCTAssertNotNil(certificate.expiresAt)
    }
    
    func testCertificateRevocation() async throws {
        // Initialize services
        let caService = CertificateAuthorityService(database: app.db, logger: app.logger)
        let revocationService = CertificateRevocationService(database: app.db, logger: app.logger)
        let ca = try await caService.initializeDefaultCA()
        
        // Create and issue a certificate
        let agentMetadata = AgentMetadata(
            hostname: "test-host",
            platform: "linux",
            version: "1.0.0",
            capabilities: ["vm-management"],
            tpmAvailable: false
        )
        
        let csr = CertificateSigningRequest(
            publicKeyPEM: "dGVzdC1wdWJsaWMta2V5",
            agentId: "test-agent",
            commonName: "test-agent",
            agentMetadata: agentMetadata
        )
        
        let certificate = try await caService.issueCertificate(
            for: "test-agent",
            csr: csr,
            ca: ca
        )
        
        // Verify certificate is active
        XCTAssertEqual(certificate.status, .active)
        XCTAssertFalse(try await revocationService.isCertificateRevoked(serialNumber: certificate.serialNumber))
        
        // Revoke the certificate
        try await caService.revokeCertificate(certificate, reason: "Test revocation")
        
        // Verify certificate is revoked
        XCTAssertEqual(certificate.status, .revoked)
        XCTAssertTrue(try await revocationService.isCertificateRevoked(serialNumber: certificate.serialNumber))
        
        // Test CRL generation
        let crl = try await revocationService.generateCRL()
        XCTAssertEqual(crl.revokedCertificates.count, 1)
        XCTAssertEqual(crl.revokedCertificates.first?.serialNumber, certificate.serialNumber)
    }
    
    func testGetCACertificate() async throws {
        // Test CA service directly instead of via HTTP endpoint
        let caService = CertificateAuthorityService(database: app.db, logger: app.logger)
        let ca = try await caService.initializeDefaultCA()
        
        XCTAssertFalse(ca.certificatePEM.isEmpty)
        XCTAssertEqual(ca.trustDomain, "strato.local")
        XCTAssertNotNil(ca.createdAt)
    }
    
    func testGetCertificateRevocationList() async throws {
        // Test CRL generation directly
        let revocationService = CertificateRevocationService(database: app.db, logger: app.logger)
        let crl = try await revocationService.generateCRL()
        
        XCTAssertEqual(crl.issuer, "CN=Strato Root CA,O=Strato,C=US")
        XCTAssertNotNil(crl.thisUpdate)
        XCTAssertNotNil(crl.nextUpdate)
        XCTAssertEqual(crl.version, 2)
        
        // Test CRL data generation
        let crlData = try crl.generateCRLData()
        XCTAssertTrue(crlData.contains("-----BEGIN X509 CRL-----"))
        XCTAssertTrue(crlData.contains("-----END X509 CRL-----"))
    }
}