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
        
        // Initialize step-ca client
        let stepCAClient = try StepCAClient(
            client: req.client,
            logger: req.logger,
            database: req.db
        )

        // Check if agent already has a valid certificate
        if let existingCert = try await AgentCertificate.query(on: req.db)
            .filter(\.$agentId == enrollmentRequest.csr.agentId)
            .filter(\.$status == .active)
            .first(),
           existingCert.isValid {
            throw Abort(.conflict, reason: "Agent already has a valid certificate")
        }

        // Generate join token for step-ca
        let joinTokenService = JoinTokenService(logger: req.logger)
        let joinToken = try joinTokenService.generateJoinToken(
            for: enrollmentRequest.csr.agentId,
            validityHours: 1,
            req: req
        )

        // Issue new certificate via step-ca
        let certificate = try await stepCAClient.issueCertificate(
            for: enrollmentRequest.csr.agentId,
            csr: enrollmentRequest.csr,
            joinToken: joinToken,
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
        
        // Get CA certificate bundle from step-ca
        let caBundlePEM = try await stepCAClient.getCACertificate()

        // Create response
        let response = AgentEnrollmentResponse(
            certificatePEM: certificate.certificatePEM,
            caBundlePEM: caBundlePEM,
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
        
        // Initialize step-ca client
        let stepCAClient = try StepCAClient(
            client: req.client,
            logger: req.logger,
            database: req.db
        )

        // Generate new join token for certificate renewal
        let joinTokenService = JoinTokenService(logger: req.logger)
        let renewalToken = try joinTokenService.generateJoinToken(
            for: agentAuth.agentId,
            validityHours: 1,
            req: req
        )

        // Issue new certificate via step-ca
        let newCertificate = try await stepCAClient.issueCertificate(
            for: agentAuth.agentId,
            csr: renewalRequest.csr,
            joinToken: renewalToken,
            validityHours: 24
        )
        
        // Revoke old certificate via step-ca
        try await stepCAClient.revokeCertificate(existingCert, reason: "Certificate renewed")

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

        // Get CA certificate bundle from step-ca
        let caBundlePEM = try await stepCAClient.getCACertificate()

        // Create response
        let response = AgentEnrollmentResponse(
            certificatePEM: newCertificate.certificatePEM,
            caBundlePEM: caBundlePEM,
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
        let stepCAClient = try StepCAClient(
            client: req.client,
            logger: req.logger,
            database: req.db
        )

        let certificatePEM = try await stepCAClient.getCACertificate()

        return CAInfo(
            certificatePEM: certificatePEM,
            trustDomain: "strato.local",
            validFrom: Date(), // Will be extracted from cert in real implementation
            validTo: Date().addingTimeInterval(10 * 365 * 24 * 60 * 60) // 10 years default
        )
    }
    
    /// Get Certificate Revocation List
    func getCertificateRevocationList(req: Request) async throws -> Response {
        let stepCAClient = try StepCAClient(
            client: req.client,
            logger: req.logger,
            database: req.db
        )

        let crlData = try await stepCAClient.getCRL()

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
            // Verify and decode JWT using configured signers
            let payload = try req.jwt.verify(token, as: JoinTokenPayload.self)

            // Check expiration (additional validation beyond JWT verification)
            guard payload.exp > Date() else {
                throw Abort(.unauthorized, reason: "Join token has expired")
            }

            // TODO: Check if token has been used (implement one-time use)

            req.logger.info("Join token validated", metadata: [
                "agentId": .string(payload.agentId),
                "expiresAt": .string(payload.exp.description)
            ])

            return payload

        } catch {
            req.logger.error("Failed to validate join token: \(error)")
            throw Abort(.unauthorized, reason: "Invalid join token")
        }
    }
}

// JoinTokenPayload is now defined in StepCAClient.swift to avoid duplication

/// Service for generating join tokens
struct JoinTokenService {
    let logger: Logger
    
    /// Generate a join token for agent enrollment using configured JWT signers
    func generateJoinToken(for agentId: String, validityHours: Int = 1, req: Request) throws -> String {
        let payload = JoinTokenPayload(agentId: agentId, validityHours: validityHours)

        let jwt = try req.jwt.sign(payload)

        logger.info("Generated join token", metadata: [
            "agentId": .string(agentId),
            "expiresAt": .string(payload.exp.description)
        ])

        return jwt
    }
}

// MARK: - Content Conformance Extensions

extension AgentEnrollmentResponse: @retroactive Content {}
extension CAInfo: @retroactive Content {}