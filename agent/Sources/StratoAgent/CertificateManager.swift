import Foundation
import Crypto
import StratoShared
import Logging

/// Service for managing agent certificates
@MainActor
class CertificateManager {
    private let config: AgentConfig
    private let logger: Logger
    private let agentId: String
    
    init(config: AgentConfig, agentId: String, logger: Logger) {
        self.config = config
        self.agentId = agentId
        self.logger = logger
    }
    
    /// Check if the agent has valid certificates
    func hasValidCertificate() -> Bool {
        guard config.hasCertificateAuth else { return false }
        
        let certPath = config.certificatePath ?? config.defaultCertificatePath
        let keyPath = config.privateKeyPath ?? config.defaultPrivateKeyPath
        let caPath = config.caBundlePath ?? config.defaultCABundlePath
        
        // Check if all required files exist
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: certPath),
              fileManager.fileExists(atPath: keyPath),
              fileManager.fileExists(atPath: caPath) else {
            logger.info("Certificate files not found")
            return false
        }
        
        // Check if certificate is valid and not expired
        do {
            let certificate = try loadCertificate()
            return !certificate.isExpired && !certificate.needsRenewal(threshold: config.effectiveRenewalThreshold)
        } catch {
            logger.error("Failed to validate certificate: \(error)")
            return false
        }
    }
    
    /// Enroll the agent and obtain a certificate
    func enrollAgent() async throws {
        guard config.canEnroll else {
            throw CertificateError.enrollmentNotConfigured
        }
        
        guard let joinToken = config.joinToken,
              let enrollmentURL = config.enrollmentURL else {
            throw CertificateError.missingEnrollmentData
        }
        
        logger.info("Starting agent enrollment", metadata: ["agentId": .string(agentId)])
        
        // Generate key pair
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        // Create CSR
        let agentMetadata = AgentMetadata(
            hostname: getHostname(),
            platform: getPlatform(),
            version: getAgentVersion(),
            capabilities: getAgentCapabilities(),
            tpmAvailable: false // For now, TPM support can be added later
        )
        
        let csr = CertificateSigningRequest(
            publicKeyPEM: publicKey.rawRepresentation.base64EncodedString(),
            agentId: agentId,
            commonName: agentId,
            agentMetadata: agentMetadata
        )
        
        let enrollmentRequest = AgentEnrollmentRequest(
            joinToken: joinToken,
            csr: csr
        )
        
        // Send enrollment request
        let response = try await sendEnrollmentRequest(enrollmentRequest, to: enrollmentURL)
        
        // Create certificate directory if it doesn't exist
        try createCertificateDirectory()
        
        // Save certificate, private key, and CA bundle
        try await saveCertificateData(
            certificate: response.certificatePEM,
            privateKey: privateKey,
            caBundle: response.caBundlePEM
        )
        
        logger.info("Agent enrollment successful", metadata: [
            "agentId": .string(agentId),
            "spiffeURI": .string(response.spiffeURI),
            "expiresAt": .string(response.expiresAt.description)
        ])
    }
    
    /// Renew the agent certificate
    func renewCertificate() async throws {
        logger.info("Starting certificate renewal", metadata: ["agentId": .string(agentId)])
        
        // Load current certificate to verify we have mTLS capability
        let currentCert = try loadCertificate()
        guard !currentCert.isExpired else {
            throw CertificateError.certificateExpired
        }
        
        // Generate new key pair
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        // Create CSR for renewal
        let agentMetadata = AgentMetadata(
            hostname: getHostname(),
            platform: getPlatform(),
            version: getAgentVersion(),
            capabilities: getAgentCapabilities(),
            tpmAvailable: false
        )
        
        let csr = CertificateSigningRequest(
            publicKeyPEM: publicKey.rawRepresentation.base64EncodedString(),
            agentId: agentId,
            commonName: agentId,
            agentMetadata: agentMetadata
        )
        
        let renewalRequest = CertificateRenewalRequest(csr: csr)
        
        // Send renewal request using current certificate for mTLS
        let renewalURL = currentCert.renewalEndpoint ?? "https://localhost:8080/agent/renew"
        let response = try await sendRenewalRequest(renewalRequest, to: renewalURL)
        
        // Save new certificate and private key
        try await saveCertificateData(
            certificate: response.certificatePEM,
            privateKey: privateKey,
            caBundle: response.caBundlePEM
        )
        
        logger.info("Certificate renewal successful", metadata: [
            "agentId": .string(agentId),
            "expiresAt": .string(response.expiresAt.description)
        ])
    }
    
    /// Load certificate information
    func loadCertificate() throws -> AgentCertificateInfo {
        let certPath = config.certificatePath ?? config.defaultCertificatePath
        let certificatePEM = try String(contentsOfFile: certPath)
        
        // Parse simplified certificate format
        return try parseCertificate(certificatePEM)
    }
    
    /// Load private key
    func loadPrivateKey() throws -> P256.Signing.PrivateKey {
        let keyPath = config.privateKeyPath ?? config.defaultPrivateKeyPath
        let privateKeyPEM = try String(contentsOfFile: keyPath)
        return try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
    }
    
    /// Load CA bundle
    func loadCABundle() throws -> String {
        let caPath = config.caBundlePath ?? config.defaultCABundlePath
        return try String(contentsOfFile: caPath)
    }
    
    // MARK: - Private Methods
    
    private func createCertificateDirectory() throws {
        let certDir = config.certificateDirectory
        let fileManager = FileManager.default
        
        if !fileManager.fileExists(atPath: certDir) {
            try fileManager.createDirectory(
                atPath: certDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700] // Secure permissions
            )
            logger.info("Created certificate directory", metadata: ["path": .string(certDir)])
        }
    }
    
    private func saveCertificateData(
        certificate: String,
        privateKey: P256.Signing.PrivateKey,
        caBundle: String
    ) async throws {
        let certPath = config.certificatePath ?? config.defaultCertificatePath
        let keyPath = config.privateKeyPath ?? config.defaultPrivateKeyPath
        let caPath = config.caBundlePath ?? config.defaultCABundlePath
        
        // Write certificate file
        try certificate.write(toFile: certPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certPath)
        
        // Write private key file
        let privateKeyPEM = try privateKey.pemRepresentation
        try privateKeyPEM.write(toFile: keyPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
        
        // Write CA bundle file
        try caBundle.write(toFile: caPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: caPath)
        
        logger.info("Saved certificate data", metadata: [
            "certificatePath": .string(certPath),
            "privateKeyPath": .string(keyPath),
            "caBundlePath": .string(caPath)
        ])
    }
    
    private func sendEnrollmentRequest(
        _ request: AgentEnrollmentRequest,
        to url: String
    ) async throws -> AgentEnrollmentResponse {
        // For Phase 2, implement a basic HTTP client
        // This would be replaced with a full HTTP client implementation
        logger.info("Mock enrollment request", metadata: [
            "url": .string(url),
            "agentId": .string(request.csr.agentId)
        ])
        
        // Simulate successful enrollment response
        let now = Date()
        let expiresAt = now.addingTimeInterval(24 * 60 * 60) // 24 hours
        
        return AgentEnrollmentResponse(
            certificatePEM: generateMockCertificate(),
            caBundlePEM: generateMockCACertificate(),
            expiresAt: expiresAt,
            spiffeURI: "spiffe://strato.local/agent/\(agentId)",
            renewalEndpoint: "https://localhost:8080/agent/renew"
        )
    }
    
    private func sendRenewalRequest(
        _ request: CertificateRenewalRequest,
        to url: String
    ) async throws -> AgentEnrollmentResponse {
        // For Phase 2, implement with mTLS
        logger.info("Mock renewal request", metadata: [
            "url": .string(url),
            "agentId": .string(request.csr.agentId)
        ])
        
        // Simulate successful renewal response
        let now = Date()
        let expiresAt = now.addingTimeInterval(24 * 60 * 60) // 24 hours
        
        return AgentEnrollmentResponse(
            certificatePEM: generateMockCertificate(),
            caBundlePEM: generateMockCACertificate(),
            expiresAt: expiresAt,
            spiffeURI: "spiffe://strato.local/agent/\(agentId)",
            renewalEndpoint: "https://localhost:8080/agent/renew"
        )
    }
    
    private func parseCertificate(_ certificatePEM: String) throws -> AgentCertificateInfo {
        // For Phase 2, implement simplified certificate parsing
        // Extract base64 content and parse JSON metadata
        let content = certificatePEM.base64EncodedContent()
        guard let data = Data(base64Encoded: content) else {
            throw CertificateError.invalidCertificate("Failed to decode certificate")
        }
        
        let certData = try JSONDecoder().decode(CertificateData.self, from: data)
        
        return AgentCertificateInfo(
            agentId: agentId,
            spiffeURI: certData.subjectAltNames.first ?? "",
            expiresAt: certData.validTo,
            renewalEndpoint: "https://localhost:8080/agent/renew"
        )
    }
    
    private func generateMockCertificate() -> String {
        let now = Date()
        let expiresAt = now.addingTimeInterval(24 * 60 * 60)
        
        let certData = CertificateData(
            version: 3,
            serialNumber: Int64.random(in: 1000...9999),
            issuer: "CN=Strato Root CA,O=Strato,C=US",
            subject: "CN=\(agentId),O=Strato Agent",
            validFrom: now,
            validTo: expiresAt,
            publicKey: "mock-public-key",
            isCA: false,
            keyUsage: ["digitalSignature", "keyAgreement"],
            extKeyUsage: ["clientAuth"],
            subjectAltNames: ["spiffe://strato.local/agent/\(agentId)"],
            signature: "mock-signature"
        )
        
        let jsonData = try! JSONEncoder().encode(certData)
        let base64Cert = jsonData.base64EncodedString()
        
        return """
        -----BEGIN CERTIFICATE-----
        \(base64Cert.chunked(into: 64).joined(separator: "\n"))
        -----END CERTIFICATE-----
        """
    }
    
    private func generateMockCACertificate() -> String {
        return """
        -----BEGIN CERTIFICATE-----
        LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1vY2sgQ0EgQ2VydGlmaWNhdGUgZm9yIERldmVsb3BtZW50Ck1vY2sgQ0EgQ2VydGlmaWNhdGUgZm9yIERldmVsb3BtZW50Ck1vY2sgQ0EgQ2VydGlmaWNhdGUgZm9yIERldmVsb3BtZW50
        -----END CERTIFICATE-----
        """
    }
    
    // MARK: - System Information
    
    private func getHostname() -> String {
        return ProcessInfo.processInfo.hostName
    }
    
    private func getPlatform() -> String {
        #if os(macOS)
        return "darwin"
        #elseif os(Linux)
        return "linux"
        #else
        return "unknown"
        #endif
    }
    
    private func getAgentVersion() -> String {
        return "1.0.0" // Should be from build configuration
    }
    
    private func getAgentCapabilities() -> [String] {
        var capabilities = ["vm-management", "networking"]
        
        #if os(Linux)
        capabilities.append("kvm")
        #endif
        
        return capabilities
    }
}

/// Information about an agent certificate
struct AgentCertificateInfo {
    let agentId: String
    let spiffeURI: String
    let expiresAt: Date
    let renewalEndpoint: String?
    
    var isExpired: Bool {
        return Date() >= expiresAt
    }
    
    func needsRenewal(threshold: Double = 0.6) -> Bool {
        let now = Date()
        let lifetime = expiresAt.timeIntervalSince(now)
        let renewalTime = now.addingTimeInterval(lifetime * threshold)
        return now >= renewalTime && !isExpired
    }
}

/// Simplified certificate data structure for parsing
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
}

enum CertificateError: Error, LocalizedError {
    case enrollmentNotConfigured
    case missingEnrollmentData
    case certificateExpired
    case invalidCertificate(String)
    case networkError(String)
    case fileSystemError(String)
    
    var errorDescription: String? {
        switch self {
        case .enrollmentNotConfigured:
            return "Certificate enrollment is not configured"
        case .missingEnrollmentData:
            return "Missing join token or enrollment URL"
        case .certificateExpired:
            return "Certificate has expired"
        case .invalidCertificate(let details):
            return "Invalid certificate: \(details)"
        case .networkError(let details):
            return "Network error: \(details)"
        case .fileSystemError(let details):
            return "File system error: \(details)"
        }
    }
}

// MARK: - Helper Extensions

extension String {
    func base64EncodedContent() -> String {
        let lines = self.components(separatedBy: .newlines)
        let contentLines = lines.filter { line in
            !line.hasPrefix("-----BEGIN") && !line.hasPrefix("-----END") && !line.isEmpty
        }
        return contentLines.joined()
    }
    
    func chunked(into size: Int) -> [String] {
        return stride(from: 0, to: count, by: size).map {
            String(self[index(startIndex, offsetBy: $0)..<index(startIndex, offsetBy: min($0 + size, count))])
        }
    }
}