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
                "timestamp": .string((event.timestamp ?? Date()).description)
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




