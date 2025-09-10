import Fluent
import Vapor
import StratoShared

/// Agent certificate model for storing issued certificates and metadata
final class AgentCertificate: Model, Content, @unchecked Sendable {
    static let schema = "agent_certificates"
    
    @ID(key: .id)
    var id: UUID?
    
    @Field(key: "agent_id")
    var agentId: String
    
    @Field(key: "spiffe_uri")
    var spiffeURI: String
    
    @Field(key: "certificate_pem")
    var certificatePEM: String
    
    @Field(key: "serial_number")
    var serialNumber: String
    
    @Enum(key: "status")
    var status: CertificateStatus
    
    @Parent(key: "ca_id")
    var certificateAuthority: CertificateAuthority
    
    @Timestamp(key: "issued_at", on: .none)
    var issuedAt: Date?
    
    @Timestamp(key: "expires_at", on: .none)
    var expiresAt: Date?
    
    @Timestamp(key: "revoked_at", on: .none)
    var revokedAt: Date?
    
    @Field(key: "revocation_reason")
    var revocationReason: String?
    
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?
    
    init() { }
    
    init(
        id: UUID? = nil,
        agentId: String,
        spiffeURI: String,
        certificatePEM: String,
        serialNumber: String,
        status: CertificateStatus = .active,
        caId: UUID,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.agentId = agentId
        self.spiffeURI = spiffeURI
        self.certificatePEM = certificatePEM
        self.serialNumber = serialNumber
        self.status = status
        self.$certificateAuthority.id = caId
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
    
    /// Check if certificate is currently valid
    var isValid: Bool {
        guard let expiresAt = expiresAt else { return false }
        return status == .active && Date() < expiresAt
    }
    
    /// Check if certificate is approaching expiration (within renewal window)
    func needsRenewal(renewalThreshold: Double = 0.6) -> Bool {
        guard let issuedAt = issuedAt,
              let expiresAt = expiresAt else { return false }
        
        let lifetime = expiresAt.timeIntervalSince(issuedAt)
        let renewalTime = issuedAt.addingTimeInterval(lifetime * renewalThreshold)
        
        return Date() >= renewalTime && isValid
    }
    
    /// Revoke this certificate
    func revoke(reason: String? = nil) {
        self.status = .revoked
        self.revokedAt = Date()
        self.revocationReason = reason
    }
}

enum CertificateStatus: String, Codable, CaseIterable {
    case active = "active"
    case expired = "expired"
    case revoked = "revoked"
}

// MARK: - DTO for API responses

struct AgentCertificateResponse: Content {
    let id: UUID
    let agentId: String
    let spiffeURI: String
    let serialNumber: String
    let status: CertificateStatus
    let issuedAt: Date?
    let expiresAt: Date?
    let revokedAt: Date?
    let revocationReason: String?
    let isValid: Bool
    let needsRenewal: Bool
    
    init(from certificate: AgentCertificate) throws {
        guard let id = certificate.id else {
            throw Abort(.internalServerError, reason: "Certificate missing ID")
        }
        
        self.id = id
        self.agentId = certificate.agentId
        self.spiffeURI = certificate.spiffeURI
        self.serialNumber = certificate.serialNumber
        self.status = certificate.status
        self.issuedAt = certificate.issuedAt
        self.expiresAt = certificate.expiresAt
        self.revokedAt = certificate.revokedAt
        self.revocationReason = certificate.revocationReason
        self.isValid = certificate.isValid
        self.needsRenewal = certificate.needsRenewal()
    }
}