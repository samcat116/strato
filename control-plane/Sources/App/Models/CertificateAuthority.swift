import Fluent
import Vapor
import Crypto
import Foundation

/// Certificate Authority model for storing CA certificates and metadata
final class CertificateAuthority: Model, Content, @unchecked Sendable {
    static let schema = "certificate_authorities"
    
    @ID(key: .id)
    var id: UUID?
    
    @Field(key: "name")
    var name: String
    
    @Field(key: "trust_domain")
    var trustDomain: String
    
    @Field(key: "certificate_pem")
    var certificatePEM: String
    
    @Field(key: "private_key_pem")
    var privateKeyPEM: String
    
    @Field(key: "serial_counter")
    var serialCounter: Int64
    
    @Enum(key: "status")
    var status: CAStatus
    
    @Timestamp(key: "valid_from", on: .none)
    var validFrom: Date?
    
    @Timestamp(key: "valid_to", on: .none)
    var validTo: Date?
    
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?
    
    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?
    
    init() { }
    
    init(
        id: UUID? = nil,
        name: String,
        trustDomain: String,
        certificatePEM: String,
        privateKeyPEM: String,
        status: CAStatus = .active,
        validFrom: Date,
        validTo: Date,
        serialCounter: Int64 = 1
    ) {
        self.id = id
        self.name = name
        self.trustDomain = trustDomain
        self.certificatePEM = certificatePEM
        self.privateKeyPEM = privateKeyPEM
        self.status = status
        self.validFrom = validFrom
        self.validTo = validTo
        self.serialCounter = serialCounter
    }
    
    /// Generate next serial number for certificate issuance
    func nextSerialNumber() -> Int64 {
        serialCounter += 1
        return serialCounter
    }
    
    /// Check if CA is still valid
    var isValid: Bool {
        guard let validFrom = validFrom,
              let validTo = validTo else { return false }
        
        let now = Date()
        return status == .active && 
               now >= validFrom && 
               now <= validTo
    }
}

enum CAStatus: String, Codable, CaseIterable {
    case active = "active"
    case retired = "retired"
    case revoked = "revoked"
}