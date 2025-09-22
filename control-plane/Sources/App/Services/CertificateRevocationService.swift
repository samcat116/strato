import Vapor
import Fluent
import Foundation

/// Service for managing certificate revocation and validation
struct CertificateRevocationService {
    let database: Database
    let logger: Logger
    
    init(database: Database, logger: Logger) {
        self.database = database
        self.logger = logger
    }
    
    /// Check if a certificate is revoked
    func isCertificateRevoked(serialNumber: String) async throws -> Bool {
        let certificate = try await AgentCertificate.query(on: database)
            .filter(\.$serialNumber == serialNumber)
            .first()
        
        return certificate?.status == .revoked
    }
    
    /// Get revoked certificate serial numbers for CRL generation
    func getRevokedCertificates() async throws -> [RevokedCertificate] {
        let revokedCerts = try await AgentCertificate.query(on: database)
            .filter(\.$status == .revoked)
            .all()
        
        return revokedCerts.compactMap { cert in
            guard let revokedAt = cert.revokedAt else { return nil }
            return RevokedCertificate(
                serialNumber: cert.serialNumber,
                revokedAt: revokedAt,
                reason: cert.revocationReason
            )
        }
    }
    
    /// Revoke certificates for a specific agent (e.g., when agent is compromised)
    func revokeAgentCertificates(agentId: String, reason: String) async throws {
        let certificates = try await AgentCertificate.query(on: database)
            .filter(\.$agentId == agentId)
            .filter(\.$status == .active)
            .all()
        
        for certificate in certificates {
            certificate.revoke(reason: reason)
            try await certificate.save(on: database)
        }
        
        if !certificates.isEmpty {
            logger.warning("Revoked \(certificates.count) certificates for compromised agent", metadata: [
                "agentId": .string(agentId),
                "reason": .string(reason)
            ])
        }
    }
    
    /// Cleanup expired certificates (mark as expired)
    func cleanupExpiredCertificates() async throws -> Int {
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
        
        return expiredCerts.count
    }
    
    /// Get certificates that need renewal soon
    func getCertificatesNeedingRenewal(threshold: Double = 0.6) async throws -> [AgentCertificate] {
        let certificates = try await AgentCertificate.query(on: database)
            .filter(\.$status == .active)
            .all()
        
        return certificates.filter { $0.needsRenewal(renewalThreshold: threshold) }
    }
    
    /// Generate Certificate Revocation List (CRL) data
    func generateCRL() async throws -> CertificateRevocationList {
        let revokedCerts = try await getRevokedCertificates()
        
        return CertificateRevocationList(
            issuer: "CN=Strato Root CA,O=Strato,C=US",
            thisUpdate: Date(),
            nextUpdate: Date().addingTimeInterval(24 * 60 * 60), // 24 hours
            revokedCertificates: revokedCerts
        )
    }
}

/// Information about a revoked certificate
struct RevokedCertificate: Codable {
    let serialNumber: String
    let revokedAt: Date
    let reason: String?
}

/// Certificate Revocation List structure
struct CertificateRevocationList: Codable {
    let issuer: String
    let thisUpdate: Date
    let nextUpdate: Date
    let revokedCertificates: [RevokedCertificate]
    let version: Int

    init(issuer: String, thisUpdate: Date, nextUpdate: Date, revokedCertificates: [RevokedCertificate]) {
        self.issuer = issuer
        self.thisUpdate = thisUpdate
        self.nextUpdate = nextUpdate
        self.revokedCertificates = revokedCertificates
        self.version = 2
    }
    
    /// Generate CRL in simplified format
    func generateCRLData() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        let base64CRL = data.base64EncodedString()
        
        return """
        -----BEGIN X509 CRL-----
        \(base64CRL.chunked(into: 64).joined(separator: "\n"))
        -----END X509 CRL-----
        """
    }
}

/// Scheduled task service for certificate maintenance
actor CertificateMaintenanceService {
    private let database: Database
    private let logger: Logger
    private var maintenanceTask: Task<Void, Error>?
    
    init(database: Database, logger: Logger) {
        self.database = database
        self.logger = logger
    }
    
    /// Start periodic certificate maintenance
    func startMaintenance() {
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await self?.performMaintenance()
                    // Run maintenance every hour
                    try await Task.sleep(for: .seconds(3600))
                } catch {
                    self?.logger.error("Certificate maintenance failed: \(error)")
                    // Retry after 10 minutes on error
                    try await Task.sleep(for: .seconds(600))
                }
            }
        }
        
        logger.info("Started certificate maintenance service")
    }
    
    /// Stop maintenance service
    func stopMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = nil
        logger.info("Stopped certificate maintenance service")
    }
    
    /// Perform routine certificate maintenance
    private func performMaintenance() async throws {
        let revocationService = CertificateRevocationService(database: database, logger: logger)
        
        // Clean up expired certificates
        let expiredCount = try await revocationService.cleanupExpiredCertificates()
        
        // Log certificates needing renewal
        let renewalCerts = try await revocationService.getCertificatesNeedingRenewal()
        if !renewalCerts.isEmpty {
            logger.info("Certificates needing renewal", metadata: [
                "count": .stringConvertible(renewalCerts.count),
                "agentIds": .array(renewalCerts.map { .string($0.agentId) })
            ])
        }
        
        if expiredCount > 0 || !renewalCerts.isEmpty {
            logger.info("Certificate maintenance completed", metadata: [
                "expiredCertificates": .stringConvertible(expiredCount),
                "certificatesNeedingRenewal": .stringConvertible(renewalCerts.count)
            ])
        }
    }
}