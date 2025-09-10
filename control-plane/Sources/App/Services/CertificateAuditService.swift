import Vapor
import Fluent
import Foundation

/// Audit logging service for certificate operations
struct CertificateAuditService {
    let database: Database
    let logger: Logger
    
    init(database: Database, logger: Logger) {
        self.database = database
        self.logger = logger
    }
    
    /// Log certificate enrollment event
    func logEnrollment(agentId: String, certificateId: UUID, spiffeURI: String, clientIP: String?) async {
        let event = CertificateAuditEvent(
            eventType: .enrollment,
            agentId: agentId,
            certificateId: certificateId,
            spiffeURI: spiffeURI,
            clientIP: clientIP,
            details: "Agent certificate enrolled successfully"
        )
        
        await logEvent(event)
    }
    
    /// Log certificate renewal event
    func logRenewal(agentId: String, oldCertificateId: UUID, newCertificateId: UUID, spiffeURI: String, clientIP: String?) async {
        let event = CertificateAuditEvent(
            eventType: .renewal,
            agentId: agentId,
            certificateId: newCertificateId,
            spiffeURI: spiffeURI,
            clientIP: clientIP,
            details: "Certificate renewed (old: \(oldCertificateId.uuidString), new: \(newCertificateId.uuidString))"
        )
        
        await logEvent(event)
    }
    
    /// Log certificate revocation event
    func logRevocation(agentId: String, certificateId: UUID, reason: String, clientIP: String?) async {
        let event = CertificateAuditEvent(
            eventType: .revocation,
            agentId: agentId,
            certificateId: certificateId,
            spiffeURI: nil,
            clientIP: clientIP,
            details: "Certificate revoked: \(reason)"
        )
        
        await logEvent(event)
    }
    
    /// Log certificate validation event
    func logValidation(agentId: String, certificateId: UUID, spiffeURI: String, clientIP: String?, success: Bool) async {
        let event = CertificateAuditEvent(
            eventType: .validation,
            agentId: agentId,
            certificateId: certificateId,
            spiffeURI: spiffeURI,
            clientIP: clientIP,
            details: success ? "Certificate validation successful" : "Certificate validation failed"
        )
        
        await logEvent(event)
    }
    
    /// Log suspicious activity
    func logSuspiciousActivity(agentId: String?, details: String, clientIP: String?) async {
        let event = CertificateAuditEvent(
            eventType: .suspiciousActivity,
            agentId: agentId,
            certificateId: nil,
            spiffeURI: nil,
            clientIP: clientIP,
            details: details
        )
        
        await logEvent(event)
    }
    
    /// Get audit events for a specific agent
    func getAuditEvents(for agentId: String, limit: Int = 100) async throws -> [CertificateAuditEvent] {
        return try await CertificateAuditEvent.query(on: database)
            .filter(\.$agentId == agentId)
            .sort(\.$timestamp, .descending)
            .limit(limit)
            .all()
    }
    
    /// Get recent suspicious activities
    func getSuspiciousActivities(since: Date) async throws -> [CertificateAuditEvent] {
        return try await CertificateAuditEvent.query(on: database)
            .filter(\.$eventType == .suspiciousActivity)
            .filter(\.$timestamp >= since)
            .sort(\.$timestamp, .descending)
            .all()
    }
    
    /// Private method to log events
    private func logEvent(_ event: CertificateAuditEvent) async {
        do {
            try await event.save(on: database)
            
            // Also log to structured logger for external systems
            logger.info("Certificate audit event", metadata: [
                "eventType": .string(event.eventType.rawValue),
                "agentId": .string(event.agentId ?? "unknown"),
                "certificateId": .string(event.certificateId?.uuidString ?? "none"),
                "spiffeURI": .string(event.spiffeURI ?? "none"),
                "clientIP": .string(event.clientIP ?? "unknown"),
                "details": .string(event.details),
                "timestamp": .string(event.timestamp.description)
            ])
        } catch {
            logger.error("Failed to save audit event: \(error)")
        }
    }
}

/// Database model for certificate audit events
final class CertificateAuditEvent: Model, Content, @unchecked Sendable {
    static let schema = "certificate_audit_events"
    
    @ID(key: .id)
    var id: UUID?
    
    @Enum(key: "event_type")
    var eventType: CertificateAuditEventType
    
    @OptionalField(key: "agent_id")
    var agentId: String?
    
    @OptionalField(key: "certificate_id")
    var certificateId: UUID?
    
    @OptionalField(key: "spiffe_uri")
    var spiffeURI: String?
    
    @OptionalField(key: "client_ip")
    var clientIP: String?
    
    @Field(key: "details")
    var details: String
    
    @Timestamp(key: "timestamp", on: .create)
    var timestamp: Date?
    
    init() { }
    
    init(
        eventType: CertificateAuditEventType,
        agentId: String?,
        certificateId: UUID?,
        spiffeURI: String?,
        clientIP: String?,
        details: String
    ) {
        self.eventType = eventType
        self.agentId = agentId
        self.certificateId = certificateId
        self.spiffeURI = spiffeURI
        self.clientIP = clientIP
        self.details = details
    }
}

enum CertificateAuditEventType: String, Codable, CaseIterable {
    case enrollment = "enrollment"
    case renewal = "renewal"
    case revocation = "revocation"
    case validation = "validation"
    case suspiciousActivity = "suspicious_activity"
}

/// SPIRE integration preparation service
struct SPIREMigrationService {
    let logger: Logger
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    /// Generate SPIRE configuration for eventual migration
    func generateSPIREConfig(trustDomain: String, controlPlaneAddress: String) -> SPIREConfiguration {
        return SPIREConfiguration(
            trustDomain: trustDomain,
            serverConfig: SPIREServerConfig(
                bindAddress: controlPlaneAddress,
                bindPort: 8081,
                trustDomain: trustDomain,
                dataDir: "/opt/spire/data/server",
                logLevel: "INFO",
                ca: SPIRECAConfig(
                    subject: SPIRESubject(
                        country: "US",
                        organization: "Strato",
                        commonName: "Strato SPIRE CA"
                    ),
                    ttl: "168h" // 1 week
                )
            ),
            agentConfig: SPIREAgentConfig(
                serverAddress: controlPlaneAddress,
                serverPort: 8081,
                trustDomain: trustDomain,
                dataDir: "/opt/spire/data/agent",
                logLevel: "INFO",
                socketPath: "/tmp/spire-agent/public/api.sock"
            )
        )
    }
    
    /// Check current certificate compatibility with SPIRE
    func checkSPIRECompatibility() -> SPIRECompatibilityReport {
        // For now, return basic compatibility info
        // In a real migration, this would analyze existing certificates
        return SPIRECompatibilityReport(
            isCompatible: true,
            issues: [],
            recommendations: [
                "Current SPIFFE URIs are compatible with SPIRE",
                "Consider migrating to SPIRE Workload API for better security",
                "Plan certificate TTL reduction for improved security posture"
            ]
        )
    }
}

/// SPIRE configuration structures
struct SPIREConfiguration: Codable {
    let trustDomain: String
    let serverConfig: SPIREServerConfig
    let agentConfig: SPIREAgentConfig
}

struct SPIREServerConfig: Codable {
    let bindAddress: String
    let bindPort: Int
    let trustDomain: String
    let dataDir: String
    let logLevel: String
    let ca: SPIRECAConfig
}

struct SPIREAgentConfig: Codable {
    let serverAddress: String
    let serverPort: Int
    let trustDomain: String
    let dataDir: String
    let logLevel: String
    let socketPath: String
}

struct SPIRECAConfig: Codable {
    let subject: SPIRESubject
    let ttl: String
}

struct SPIRESubject: Codable {
    let country: String
    let organization: String
    let commonName: String
}

struct SPIRECompatibilityReport: Codable {
    let isCompatible: Bool
    let issues: [String]
    let recommendations: [String]
}

/// Security hardening service
struct CertificateSecurityService {
    let logger: Logger
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    /// Validate that certificates use approved cryptographic algorithms
    func validateCryptographicStandards(certificatePEM: String) -> SecurityValidationResult {
        var issues: [String] = []
        var warnings: [String] = []
        
        // For Phase 5, implement basic validation
        // In production, this would parse actual certificates and validate algorithms
        
        // Parse simplified certificate to check algorithm usage
        do {
            let content = certificatePEM.base64EncodedContent()
            guard let data = Data(base64Encoded: content) else {
                issues.append("Invalid certificate format")
                return SecurityValidationResult(isValid: false, issues: issues, warnings: warnings)
            }
            
            let certData = try JSONDecoder().decode(CertificateData.self, from: data)
            
            // Check for deprecated algorithms (this is simplified for demo)
            if certData.signature.contains("RSA") {
                warnings.append("RSA signatures are deprecated, prefer ECDSA P-256 or Ed25519")
            }
            
            // Check certificate lifetime
            let lifetime = certData.validTo.timeIntervalSince(certData.validFrom)
            if lifetime > (30 * 24 * 60 * 60) { // 30 days
                warnings.append("Certificate lifetime exceeds recommended 30 days")
            }
            
            // Check for required extensions
            if !certData.extKeyUsage?.contains("clientAuth") ?? true {
                issues.append("Certificate missing required clientAuth extended key usage")
            }
            
        } catch {
            issues.append("Failed to parse certificate: \(error.localizedDescription)")
        }
        
        return SecurityValidationResult(
            isValid: issues.isEmpty,
            issues: issues,
            warnings: warnings
        )
    }
    
    /// Generate security recommendations
    func generateSecurityRecommendations() -> [SecurityRecommendation] {
        return [
            SecurityRecommendation(
                priority: .high,
                category: .cryptography,
                title: "Enforce ECDSA P-256 or Ed25519",
                description: "Disable RSA certificate generation and require modern elliptic curve cryptography",
                implementation: "Update CertificateAuthorityService to reject RSA key submissions"
            ),
            SecurityRecommendation(
                priority: .high,
                category: .keyManagement,
                title: "Implement TPM attestation",
                description: "Use TPM hardware security modules for key generation and storage when available",
                implementation: "Integrate with platform TPM APIs for hardware-backed key storage"
            ),
            SecurityRecommendation(
                priority: .medium,
                category: .certificateLifecycle,
                title: "Reduce certificate lifetimes",
                description: "Decrease certificate validity to 24 hours or less for improved security",
                implementation: "Update default certificate TTL and implement more frequent auto-renewal"
            ),
            SecurityRecommendation(
                priority: .medium,
                category: .monitoring,
                title: "Implement certificate transparency",
                description: "Log all certificate issuance to a certificate transparency log",
                implementation: "Integrate with public CT logs or implement internal certificate logging"
            ),
            SecurityRecommendation(
                priority: .low,
                category: .migration,
                title: "Plan SPIRE migration",
                description: "Evaluate migration to SPIFFE/SPIRE for standardized workload identity",
                implementation: "Deploy SPIRE infrastructure and plan gradual migration from custom CA"
            )
        ]
    }
}

struct SecurityValidationResult {
    let isValid: Bool
    let issues: [String]
    let warnings: [String]
}

struct SecurityRecommendation: Codable {
    let priority: SecurityPriority
    let category: SecurityCategory
    let title: String
    let description: String
    let implementation: String
}

enum SecurityPriority: String, Codable {
    case high = "high"
    case medium = "medium"
    case low = "low"
}

enum SecurityCategory: String, Codable {
    case cryptography = "cryptography"
    case keyManagement = "key_management"
    case certificateLifecycle = "certificate_lifecycle"
    case monitoring = "monitoring"
    case migration = "migration"
}

/// Simplified certificate data for parsing
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

// MARK: - Helper Extensions

extension String {
    func base64EncodedContent() -> String {
        let lines = self.components(separatedBy: .newlines)
        let contentLines = lines.filter { line in
            !line.hasPrefix("-----BEGIN") && !line.hasPrefix("-----END") && !line.isEmpty
        }
        return contentLines.joined()
    }
}