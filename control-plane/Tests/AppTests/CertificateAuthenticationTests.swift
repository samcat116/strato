import XCTest
import Vapor
import FluentSQLiteDriver
@testable import App
import StratoShared

final class CertificateAuthenticationTests: XCTestCase {
    var app: Application!
    
    override func setUp() async throws {
        app = Application(.testing)
        
        // Configure in-memory SQLite for testing
        app.databases.use(.sqlite(.memory), as: .psql)
        
        // Add migrations
        app.migrations.add(CreateCertificateAuthority())
        app.migrations.add(CreateAgentCertificate())
        
        try await app.autoMigrate()
    }
    
    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }
    
    func testCertificateEnrollmentFlow() async throws {
        // Create join token service
        let joinTokenService = JoinTokenService(logger: app.logger)
        let joinToken = try joinTokenService.generateJoinToken(for: "test-agent")
        
        // Create enrollment request
        let agentMetadata = AgentMetadata(
            hostname: "test-host",
            platform: "linux",
            version: "1.0.0",
            capabilities: ["vm-management"],
            tpmAvailable: false
        )
        
        let csr = CertificateSigningRequest(
            publicKeyPEM: "dGVzdC1wdWJsaWMta2V5", // base64 "test-public-key"
            agentId: "test-agent",
            commonName: "test-agent",
            agentMetadata: agentMetadata
        )
        
        let enrollmentRequest = AgentEnrollmentRequest(
            joinToken: joinToken,
            csr: csr
        )
        
        // Test enrollment endpoint
        try await app.test(.POST, "/agent/enroll") { req in
            try req.content.encode(enrollmentRequest)
        } afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            
            let response = try res.content.decode(AgentEnrollmentResponse.self)
            XCTAssertFalse(response.certificatePEM.isEmpty)
            XCTAssertFalse(response.caBundlePEM.isEmpty)
            XCTAssertTrue(response.spiffeURI.hasPrefix("spiffe://"))
            XCTAssertEqual(response.renewalEndpoint, "/agent/renew")
        }
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
        try await app.test(.GET, "/agent/ca") { _ in
            // No body needed for GET request
        } afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            
            let caInfo = try res.content.decode(CAInfo.self)
            XCTAssertFalse(caInfo.certificatePEM.isEmpty)
            XCTAssertEqual(caInfo.trustDomain, "strato.local")
        }
    }
    
    func testGetCertificateRevocationList() async throws {
        try await app.test(.GET, "/agent/crl") { _ in
            // No body needed for GET request
        } afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.contentType?.description, "application/pkix-crl")
            
            let crlData = res.body.string
            XCTAssertTrue(crlData.contains("-----BEGIN X509 CRL-----"))
            XCTAssertTrue(crlData.contains("-----END X509 CRL-----"))
        }
    }
}