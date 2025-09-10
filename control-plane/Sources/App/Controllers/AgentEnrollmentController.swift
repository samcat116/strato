import Vapor
import Fluent
import JWT
import StratoShared

struct AgentEnrollmentController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let agentRoutes = routes.grouped("agent")
        agentRoutes.post("enroll", use: enrollAgent)
        agentRoutes.post("renew", use: renewCertificate)
        agentRoutes.get("ca", use: getCACertificate)
        agentRoutes.get("crl", use: getCertificateRevocationList)
    }
    
    /// Enroll an agent using a join token (JWT) and issue a certificate
    func enrollAgent(req: Request) async throws -> AgentEnrollmentResponse {
        let enrollmentRequest = try req.content.decode(AgentEnrollmentRequest.self)
        
        req.logger.info("Agent enrollment request received", metadata: [
            "agentId": .string(enrollmentRequest.csr.agentId)
        ])
        
        // Validate the join token (JWT)
        let payload = try await validateJoinToken(enrollmentRequest.joinToken, req: req)
        
        // Verify agent ID matches token
        guard payload.agentId == enrollmentRequest.csr.agentId else {
            throw Abort(.forbidden, reason: "Agent ID mismatch")
        }
        
        // Get or create default CA
        let caService = CertificateAuthorityService(database: req.db, logger: req.logger)
        let ca = try await caService.initializeDefaultCA()
        
        // Check if agent already has a valid certificate
        if let existingCert = try await AgentCertificate.query(on: req.db)
            .filter(\.$agentId == enrollmentRequest.csr.agentId)
            .filter(\.$status == .active)
            .first(),
           existingCert.isValid {
            throw Abort(.conflict, reason: "Agent already has a valid certificate")
        }
        
        // Issue new certificate
        let certificate = try await caService.issueCertificate(
            for: enrollmentRequest.csr.agentId,
            csr: enrollmentRequest.csr,
            ca: ca,
            validityHours: 24
        )
        
        // Log audit event
        let auditService = CertificateAuditService(database: req.db, logger: req.logger)
        await auditService.logEnrollment(
            agentId: enrollmentRequest.csr.agentId,
            certificateId: certificate.id!,
            spiffeURI: certificate.spiffeURI,
            clientIP: req.remoteAddress?.hostname
        )
        
        // Create response
        let response = AgentEnrollmentResponse(
            certificatePEM: certificate.certificatePEM,
            caBundlePEM: ca.certificatePEM,
            expiresAt: certificate.expiresAt!,
            spiffeURI: certificate.spiffeURI,
            renewalEndpoint: "/agent/renew"
        )
        
        req.logger.info("Agent enrolled successfully", metadata: [
            "agentId": .string(enrollmentRequest.csr.agentId),
            "certificateId": .string(certificate.id?.uuidString ?? "unknown")
        ])
        
        return response
    }
    
    /// Renew an existing certificate using mTLS authentication
    func renewCertificate(req: Request) async throws -> AgentEnrollmentResponse {
        // This endpoint is protected by AgentCertificateAuthMiddleware
        // Extract agent information from authenticated certificate
        guard let agentAuth = req.auth.get(AgentAuthInfo.self) else {
            throw Abort(.unauthorized, reason: "Agent authentication required")
        }
        
        let renewalRequest = try req.content.decode(CertificateRenewalRequest.self)
        
        // Verify agent ID matches certificate
        guard agentAuth.agentId == renewalRequest.csr.agentId else {
            throw Abort(.forbidden, reason: "Agent ID mismatch")
        }
        
        req.logger.info("Certificate renewal request received", metadata: [
            "agentId": .string(agentAuth.agentId)
        ])
        
        // Get existing certificate
        guard let existingCert = try await AgentCertificate.find(agentAuth.certificateId, on: req.db) else {
            throw Abort(.notFound, reason: "No active certificate found for agent")
        }
        
        // Get CA
        let caService = CertificateAuthorityService(database: req.db, logger: req.logger)
        let ca = try await caService.initializeDefaultCA()
        
        // Issue new certificate
        let newCertificate = try await caService.issueCertificate(
            for: agentAuth.agentId,
            csr: renewalRequest.csr,
            ca: ca,
            validityHours: 24
        )
        
        // Revoke old certificate
        try await caService.revokeCertificate(existingCert, reason: "Certificate renewed")
        
        // Log audit events
        let auditService = CertificateAuditService(database: req.db, logger: req.logger)
        await auditService.logRevocation(
            agentId: agentAuth.agentId,
            certificateId: existingCert.id!,
            reason: "Certificate renewed",
            clientIP: req.remoteAddress?.hostname
        )
        await auditService.logRenewal(
            agentId: agentAuth.agentId,
            oldCertificateId: existingCert.id!,
            newCertificateId: newCertificate.id!,
            spiffeURI: newCertificate.spiffeURI,
            clientIP: req.remoteAddress?.hostname
        )
        
        // Create response
        let response = AgentEnrollmentResponse(
            certificatePEM: newCertificate.certificatePEM,
            caBundlePEM: ca.certificatePEM,
            expiresAt: newCertificate.expiresAt!,
            spiffeURI: newCertificate.spiffeURI,
            renewalEndpoint: "/agent/renew"
        )
        
        req.logger.info("Certificate renewed successfully", metadata: [
            "agentId": .string(agentAuth.agentId),
            "oldCertificateId": .string(existingCert.id?.uuidString ?? "unknown"),
            "newCertificateId": .string(newCertificate.id?.uuidString ?? "unknown")
        ])
        
        return response
    }
    
    /// Get CA certificate bundle for agents
    func getCACertificate(req: Request) async throws -> CAInfo {
        let caService = CertificateAuthorityService(database: req.db, logger: req.logger)
        let ca = try await caService.initializeDefaultCA()
        
        return CAInfo(
            certificatePEM: ca.certificatePEM,
            trustDomain: ca.trustDomain,
            validFrom: ca.validFrom!,
            validTo: ca.validTo!
        )
    }
    
    /// Get Certificate Revocation List
    func getCertificateRevocationList(req: Request) async throws -> Response {
        let revocationService = CertificateRevocationService(database: req.db, logger: req.logger)
        let crl = try await revocationService.generateCRL()
        let crlData = try crl.generateCRLData()
        
        return Response(
            status: .ok,
            headers: HTTPHeaders([
                ("Content-Type", "application/pkix-crl"),
                ("Content-Disposition", "attachment; filename=\"strato-ca.crl\"")
            ]),
            body: .init(string: crlData)
        )
    }
    
    /// Validate join token (JWT) and extract agent information
    private func validateJoinToken(_ token: String, req: Request) async throws -> JoinTokenPayload {
        do {
            // Get signing key from environment or configuration
            let signingKey = Environment.get("JOIN_TOKEN_SECRET") ?? "default-secret-key"
            let hmacKey = HMACKey(from: Data(signingKey.utf8))
            
            // Verify and decode JWT
            let payload = try JWT<JoinTokenPayload>(from: token, verifiedUsing: .hs256(key: hmacKey))
            
            // Check expiration
            guard payload.expiresAt > Date() else {
                throw Abort(.unauthorized, reason: "Join token has expired")
            }
            
            // TODO: Check if token has been used (implement one-time use)
            
            req.logger.info("Join token validated", metadata: [
                "agentId": .string(payload.agentId),
                "expiresAt": .string(payload.expiresAt.description)
            ])
            
            return payload
            
        } catch {
            req.logger.error("Failed to validate join token: \(error)")
            throw Abort(.unauthorized, reason: "Invalid join token")
        }
    }
}

/// JWT payload for join tokens
struct JoinTokenPayload: JWTPayload {
    let agentId: String
    let issuedAt: Date
    let expiresAt: Date
    let issuer: String
    
    init(agentId: String, validityHours: Int = 1) {
        self.agentId = agentId
        self.issuedAt = Date()
        self.expiresAt = Date().addingTimeInterval(TimeInterval(validityHours * 3600))
        self.issuer = "strato-control-plane"
    }
    
    func verify(using signer: JWTSigner) throws {
        // Verify expiration
        guard expiresAt > Date() else {
            throw JWTError.claimVerificationFailure(name: "exp", reason: "Token has expired")
        }
    }
}

/// Service for generating join tokens
struct JoinTokenService {
    let logger: Logger
    
    /// Generate a join token for agent enrollment
    func generateJoinToken(for agentId: String, validityHours: Int = 1) throws -> String {
        let payload = JoinTokenPayload(agentId: agentId, validityHours: validityHours)
        
        let signingKey = Environment.get("JOIN_TOKEN_SECRET") ?? "default-secret-key"
        let hmacKey = HMACKey(from: Data(signingKey.utf8))
        
        let jwt = try JWT(payload: payload).sign(using: .hs256(key: hmacKey))
        
        logger.info("Generated join token", metadata: [
            "agentId": .string(agentId),
            "expiresAt": .string(payload.expiresAt.description)
        ])
        
        return jwt
    }
}