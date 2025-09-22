import Vapor
import Fluent
import Crypto
import Foundation
import StratoShared

/// Service for managing Certificate Authority operations
/// Note: This is a simplified implementation for Phase 1
/// Future versions will use full X.509 certificate parsing and generation
struct CertificateAuthorityService {
    let database: Database
    let logger: Logger
    
    init(database: Database, logger: Logger) {
        self.database = database
        self.logger = logger
    }
    
    /// Initialize the default CA if it doesn't exist
    func initializeDefaultCA() async throws -> CertificateAuthority {
        // Check if default CA already exists
        if let existingCA = try await CertificateAuthority.query(on: database)
            .filter(\.$name == "strato-default")
            .filter(\.$status == .active)
            .first() {
            logger.info("Using existing default CA", metadata: ["caId": .string(existingCA.id?.uuidString ?? "unknown")])
            return existingCA
        }
        
        logger.info("Creating new default CA")
        
        // Generate CA key pair using Swift Crypto
        let caPrivateKey = P256.Signing.PrivateKey()
        
        // Create simplified CA certificate (PEM format with metadata)
        let now = Date()
        let caValidTo = now.addingTimeInterval(10 * 365 * 24 * 60 * 60) // 10 years
        
        // Generate simplified PEM certificate for CA
        let caCertPEM = try generateSimplifiedCACertificate(
            privateKey: caPrivateKey,
            commonName: "Strato Root CA",
            validFrom: now,
            validTo: caValidTo
        )
        
        let caPrivateKeyPEM = caPrivateKey.pemRepresentation
        
        // Create CA model
        let ca = CertificateAuthority(
            name: "strato-default",
            trustDomain: "strato.local",
            certificatePEM: caCertPEM,
            privateKeyPEM: caPrivateKeyPEM,
            status: .active,
            validFrom: now,
            validTo: caValidTo,
            serialCounter: 1
        )
        
        try await ca.save(on: database)
        
        logger.info("Created default CA", metadata: [
            "caId": .string(ca.id?.uuidString ?? "unknown"),
            "trustDomain": .string(ca.trustDomain),
            "validTo": .string(caValidTo.description)
        ])
        
        return ca
    }
    
    /// Issue a certificate for an agent
    func issueCertificate(
        for agentId: String,
        csr: CertificateSigningRequest,
        ca: CertificateAuthority,
        validityHours: Int = 24
    ) async throws -> AgentCertificate {
        
        guard ca.isValid else {
            throw CertificateError.caNotValid
        }
        
        // For Phase 1, use a simplified certificate format
        // This will be replaced with full X.509 implementation in later phases
        
        // Create SPIFFE URI
        let spiffeIdentity = SPIFFEIdentity(
            trustDomain: ca.trustDomain,
            path: "/agent/\(agentId)"
        )
        
        // Generate serial number
        let serialNumber = ca.nextSerialNumber()
        
        // Create simplified certificate
        let now = Date()
        let expiresAt = now.addingTimeInterval(TimeInterval(validityHours * 3600))
        
        // Load CA private key for signing
        let caPrivateKey = try P256.Signing.PrivateKey(pemRepresentation: ca.privateKeyPEM)
        
        // Generate simplified agent certificate
        let certificatePEM = try generateSimplifiedAgentCertificate(
            agentId: agentId,
            spiffeURI: spiffeIdentity.uri,
            publicKeyPEM: csr.publicKeyPEM,
            caPrivateKey: caPrivateKey,
            caCertificatePEM: ca.certificatePEM,
            serialNumber: serialNumber,
            validFrom: now,
            validTo: expiresAt
        )
        
        // Create certificate model
        let agentCert = AgentCertificate(
            agentId: agentId,
            spiffeURI: spiffeIdentity.uri,
            certificatePEM: certificatePEM,
            serialNumber: String(serialNumber),
            status: .active,
            caId: ca.id!,
            issuedAt: now,
            expiresAt: expiresAt
        )
        
        // Save certificate and update CA serial counter
        try await ca.save(on: database)
        try await agentCert.save(on: database)
        
        logger.info("Issued certificate for agent", metadata: [
            "agentId": .string(agentId),
            "spiffeURI": .string(spiffeIdentity.uri),
            "serialNumber": .string(String(serialNumber)),
            "expiresAt": .string(expiresAt.description)
        ])
        
        return agentCert
    }
    
    /// Revoke a certificate
    func revokeCertificate(
        _ certificate: AgentCertificate,
        reason: String? = nil
    ) async throws {
        certificate.revoke(reason: reason)
        try await certificate.save(on: database)
        
        logger.info("Revoked certificate", metadata: [
            "certificateId": .string(certificate.id?.uuidString ?? "unknown"),
            "agentId": .string(certificate.agentId),
            "reason": .string(reason ?? "no reason provided")
        ])
    }
    
    /// Get all certificates that need renewal
    func getCertificatesNeedingRenewal() async throws -> [AgentCertificate] {
        let certificates = try await AgentCertificate.query(on: database)
            .filter(\.$status == .active)
            .all()
        
        return certificates.filter { $0.needsRenewal() }
    }
    
    /// Clean up expired certificates
    func cleanupExpiredCertificates() async throws {
        let expiredCerts = try await AgentCertificate.query(on: database)
            .filter(\.$status == .active)
            .filter(\.$expiresAt < Date())
            .all()
        
        for cert in expiredCerts {
            cert.status = .expired
            try await cert.save(on: database)
        }
        
        if !expiredCerts.isEmpty {
            logger.info("Marked \(expiredCerts.count) certificates as expired")
        }
    }
    
    // MARK: - Simplified Certificate Generation
    
    /// Generate a simplified CA certificate in PEM format
    private func generateSimplifiedCACertificate(
        privateKey: P256.Signing.PrivateKey,
        commonName: String,
        validFrom: Date,
        validTo: Date
    ) throws -> String {
        // Generate certificate metadata
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let signature = try privateKey.signature(for: publicKeyData)
        
        let certData = CertificateData(
            version: 3,
            serialNumber: 1,
            issuer: "CN=\(commonName),O=Strato,C=US",
            subject: "CN=\(commonName),O=Strato,C=US",
            validFrom: validFrom,
            validTo: validTo,
            publicKey: publicKeyData.base64EncodedString(),
            isCA: true,
            keyUsage: ["keyCertSign", "cRLSign", "digitalSignature"],
            subjectAltNames: [],
            signature: signature.rawRepresentation.base64EncodedString()
        )
        
        let jsonData = try JSONEncoder().encode(certData)
        let base64Cert = jsonData.base64EncodedString()
        
        return """
        -----BEGIN CERTIFICATE-----
        \(base64Cert.chunked(into: 64).joined(separator: "\n"))
        -----END CERTIFICATE-----
        """
    }
    
    /// Generate a simplified agent certificate in PEM format
    private func generateSimplifiedAgentCertificate(
        agentId: String,
        spiffeURI: String,
        publicKeyPEM: String,
        caPrivateKey: P256.Signing.PrivateKey,
        caCertificatePEM: String,
        serialNumber: Int64,
        validFrom: Date,
        validTo: Date
    ) throws -> String {
        // Extract public key from PEM
        let publicKeyData = Data(base64Encoded: publicKeyPEM.base64EncodedContent()) ?? Data()
        
        // Sign the certificate with CA private key
        let signature = try caPrivateKey.signature(for: publicKeyData)
        
        let certData = CertificateData(
            version: 3,
            serialNumber: serialNumber,
            issuer: "CN=Strato Root CA,O=Strato,C=US",
            subject: "CN=\(agentId),O=Strato Agent",
            validFrom: validFrom,
            validTo: validTo,
            publicKey: publicKeyPEM,
            isCA: false,
            keyUsage: ["digitalSignature", "keyAgreement"],
            extKeyUsage: ["clientAuth"],
            subjectAltNames: [spiffeURI],
            signature: signature.rawRepresentation.base64EncodedString()
        )
        
        let jsonData = try JSONEncoder().encode(certData)
        let base64Cert = jsonData.base64EncodedString()
        
        return """
        -----BEGIN CERTIFICATE-----
        \(base64Cert.chunked(into: 64).joined(separator: "\n"))
        -----END CERTIFICATE-----
        """
    }
}

/// Simplified certificate data structure
private struct CertificateData: Codable {
    let version: Int
    let serialNumber: Int64
    let issuer: String
    let subject: String
    let validFrom: Date
    let validTo: Date
    let publicKey: String
    let isCA: Bool
    let keyUsage: [String]
    let extKeyUsage: [String]?
    let subjectAltNames: [String]
    let signature: String
    
    init(
        version: Int,
        serialNumber: Int64,
        issuer: String,
        subject: String,
        validFrom: Date,
        validTo: Date,
        publicKey: String,
        isCA: Bool,
        keyUsage: [String],
        extKeyUsage: [String]? = nil,
        subjectAltNames: [String],
        signature: String
    ) {
        self.version = version
        self.serialNumber = serialNumber
        self.issuer = issuer
        self.subject = subject
        self.validFrom = validFrom
        self.validTo = validTo
        self.publicKey = publicKey
        self.isCA = isCA
        self.keyUsage = keyUsage
        self.extKeyUsage = extKeyUsage
        self.subjectAltNames = subjectAltNames
        self.signature = signature
    }
}

enum CertificateError: Error, LocalizedError {
    case caNotValid
    case invalidPublicKey(String)
    case certificateGeneration(String)
    case serialNumberExhausted
    
    var errorDescription: String? {
        switch self {
        case .caNotValid:
            return "Certificate Authority is not valid"
        case .invalidPublicKey(let details):
            return "Invalid public key: \(details)"
        case .certificateGeneration(let details):
            return "Failed to generate certificate: \(details)"
        case .serialNumberExhausted:
            return "CA has exhausted all serial numbers"
        }
    }
}

// MARK: - Helper Extensions

extension String {
    func base64EncodedContent() -> String {
        // Extract content between PEM headers
        let lines = self.components(separatedBy: .newlines)
        let contentLines = lines.filter { line in
            !line.hasPrefix("-----BEGIN") && !line.hasPrefix("-----END") && !line.isEmpty
        }
        return contentLines.joined()
    }
}