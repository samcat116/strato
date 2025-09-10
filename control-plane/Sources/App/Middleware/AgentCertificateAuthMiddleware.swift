import Vapor
import Fluent
import StratoShared
import NIOSSL

/// Middleware to authenticate agents using client certificates
struct AgentCertificateAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Only apply certificate authentication to agent routes
        guard request.url.path.hasPrefix("/agent/") else {
            return try await next.respond(to: request)
        }
        
        // Skip certificate auth for enrollment endpoint (uses JWT tokens)
        if request.url.path == "/agent/enroll" || request.url.path == "/agent/ca" {
            return try await next.respond(to: request)
        }
        
        // Extract client certificate from TLS connection
        guard let certificate = extractClientCertificate(from: request) else {
            throw Abort(.unauthorized, reason: "Client certificate required for agent routes")
        }
        
        // Validate certificate and extract agent information
        let agentInfo = try await validateClientCertificate(certificate, request: request)
        
        // Store agent information for use in request handlers
        request.auth.login(agentInfo)
        
        request.logger.info("Agent authenticated via certificate", metadata: [
            "agentId": .string(agentInfo.agentId),
            "spiffeURI": .string(agentInfo.spiffeURI)
        ])
        
        return try await next.respond(to: request)
    }
    
    /// Extract client certificate from the request
    private func extractClientCertificate(from request: Request) -> String? {
        // In a real TLS implementation, this would extract the certificate from the SSL context
        // For now, we'll look for a certificate in headers (for development/testing)
        
        // Check for certificate in headers (development mode)
        if let certHeader = request.headers["X-Client-Certificate"].first {
            return certHeader
        }
        
        // TODO: Extract from actual TLS connection when NIOSSL is configured
        // This would involve accessing the SSL context from the channel
        
        return nil
    }
    
    /// Validate the client certificate and extract agent information
    private func validateClientCertificate(_ certificatePEM: String, request: Request) async throws -> AgentAuthInfo {
        do {
            // Parse the simplified certificate format
            let certInfo = try parseCertificate(certificatePEM)
            
            // Verify certificate is not expired
            guard !certInfo.isExpired else {
                throw Abort(.unauthorized, reason: "Client certificate has expired")
            }
            
            // Verify certificate exists in database and is active
            guard let dbCertificate = try await AgentCertificate.query(on: request.db)
                .filter(\.$agentId == certInfo.agentId)
                .filter(\.$status == .active)
                .first() else {
                throw Abort(.unauthorized, reason: "Certificate not found or inactive")
            }
            
            // Verify certificate matches the one in database
            guard dbCertificate.certificatePEM == certificatePEM else {
                throw Abort(.unauthorized, reason: "Certificate does not match database record")
            }
            
            // Verify certificate is still valid (not approaching expiration for critical operations)
            guard dbCertificate.isValid else {
                throw Abort(.unauthorized, reason: "Certificate is no longer valid")
            }
            
            // Extract SPIFFE URI from certificate
            let spiffeURI = try extractSPIFFEURI(from: certInfo)
            
            // Validate SPIFFE URI format
            let spiffeIdentity = try SPIFFEIdentity(uri: spiffeURI)
            guard spiffeIdentity.path.hasPrefix("/agent/") else {
                throw Abort(.unauthorized, reason: "Invalid SPIFFE identity for agent")
            }
            
            request.logger.debug("Certificate validation successful", metadata: [
                "agentId": .string(certInfo.agentId),
                "spiffeURI": .string(spiffeURI),
                "expiresAt": .string(certInfo.expiresAt.description)
            ])
            
            return AgentAuthInfo(
                agentId: certInfo.agentId,
                spiffeURI: spiffeURI,
                certificateId: dbCertificate.id!,
                expiresAt: certInfo.expiresAt
            )
            
        } catch let error as Abort {
            request.logger.warning("Certificate validation failed", metadata: [
                "reason": .string(error.reason),
                "status": .stringConvertible(error.status.code)
            ])
            throw error
        } catch {
            request.logger.error("Certificate validation error: \(error)")
            throw Abort(.unauthorized, reason: "Certificate validation failed")
        }
    }
    
    /// Parse simplified certificate format
    private func parseCertificate(_ certificatePEM: String) throws -> CertificateInfo {
        // Extract base64 content from PEM
        let content = certificatePEM.base64EncodedContent()
        guard let data = Data(base64Encoded: content) else {
            throw Abort(.badRequest, reason: "Invalid certificate format")
        }
        
        // Decode certificate data
        let certData = try JSONDecoder().decode(CertificateData.self, from: data)
        
        // Extract agent ID from subject
        let agentId = try extractAgentIdFromSubject(certData.subject)
        
        return CertificateInfo(
            agentId: agentId,
            subject: certData.subject,
            subjectAltNames: certData.subjectAltNames,
            expiresAt: certData.validTo
        )
    }
    
    /// Extract agent ID from certificate subject
    private func extractAgentIdFromSubject(_ subject: String) throws -> String {
        // Parse "CN=agentId,O=Strato Agent" format
        let components = subject.split(separator: ",")
        for component in components {
            let keyValue = component.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if keyValue.count == 2 && keyValue[0].trimmingCharacters(in: .whitespaces) == "CN" {
                return String(keyValue[1].trimmingCharacters(in: .whitespaces))
            }
        }
        throw Abort(.badRequest, reason: "Cannot extract agent ID from certificate subject")
    }
    
    /// Extract SPIFFE URI from certificate subject alternative names
    private func extractSPIFFEURI(from certInfo: CertificateInfo) throws -> String {
        for san in certInfo.subjectAltNames {
            if san.hasPrefix("spiffe://") {
                return san
            }
        }
        throw Abort(.badRequest, reason: "No SPIFFE URI found in certificate")
    }
}

/// Information extracted from client certificate
struct AgentAuthInfo: Authenticatable {
    let agentId: String
    let spiffeURI: String
    let certificateId: UUID
    let expiresAt: Date
}

/// Parsed certificate information
private struct CertificateInfo {
    let agentId: String
    let subject: String
    let subjectAltNames: [String]
    let expiresAt: Date
    
    var isExpired: Bool {
        return Date() >= expiresAt
    }
}

/// Certificate data structure for parsing simplified certificates
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

/// Extension to extract base64 content from PEM format
extension String {
    func base64EncodedContent() -> String {
        let lines = self.components(separatedBy: .newlines)
        let contentLines = lines.filter { line in
            !line.hasPrefix("-----BEGIN") && !line.hasPrefix("-----END") && !line.isEmpty
        }
        return contentLines.joined()
    }
}