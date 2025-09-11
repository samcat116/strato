import Vapor
import Fluent

struct SecurityController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let securityRoutes = routes.grouped("api", "security")
        
        // Certificate security endpoints
        securityRoutes.get("audit", "events", use: getAuditEvents)
        securityRoutes.get("audit", "suspicious", use: getSuspiciousActivities)
        securityRoutes.get("recommendations", use: getSecurityRecommendations)
        securityRoutes.post("validate", "certificate", use: validateCertificateSecurity)
        
        // SPIRE migration endpoints
        securityRoutes.get("spire", "config", use: generateSPIREConfig)
        securityRoutes.get("spire", "compatibility", use: checkSPIRECompatibility)
    }
    
    /// Get audit events for certificates
    func getAuditEvents(req: Request) async throws -> [CertificateAuditEvent] {
        let agentId = req.query[String.self, at: "agentId"]
        let limit = req.query[Int.self, at: "limit"] ?? 100
        
        let auditService = CertificateAuditService(database: req.db, logger: req.logger)
        
        if let agentId = agentId {
            return try await auditService.getAuditEvents(for: agentId, limit: limit)
        } else {
            // Return recent events for all agents
            return try await CertificateAuditEvent.query(on: req.db)
                .sort(\.$timestamp, .descending)
                .limit(limit)
                .all()
        }
    }
    
    /// Get suspicious activities
    func getSuspiciousActivities(req: Request) async throws -> [CertificateAuditEvent] {
        let hoursBack = req.query[Int.self, at: "hours"] ?? 24
        let since = Date().addingTimeInterval(-TimeInterval(hoursBack * 3600))
        
        let auditService = CertificateAuditService(database: req.db, logger: req.logger)
        return try await auditService.getSuspiciousActivities(since: since)
    }
    
    /// Get security recommendations
    func getSecurityRecommendations(req: Request) async throws -> [SecurityRecommendation] {
        let securityService = CertificateSecurityService(logger: req.logger)
        return securityService.generateSecurityRecommendations()
    }
    
    /// Validate certificate security standards
    func validateCertificateSecurity(req: Request) async throws -> SecurityValidationResult {
        let request = try req.content.decode(CertificateValidationRequest.self)
        
        let securityService = CertificateSecurityService(logger: req.logger)
        return securityService.validateCryptographicStandards(certificatePEM: request.certificatePEM)
    }
    
    /// Generate SPIRE configuration
    func generateSPIREConfig(req: Request) async throws -> SPIREConfiguration {
        let trustDomain = req.query[String.self, at: "trustDomain"] ?? "strato.local"
        let controlPlaneAddress = req.query[String.self, at: "address"] ?? "localhost"
        
        let spireService = SPIREMigrationService(logger: req.logger)
        return spireService.generateSPIREConfig(
            trustDomain: trustDomain,
            controlPlaneAddress: controlPlaneAddress
        )
    }
    
    /// Check SPIRE compatibility
    func checkSPIRECompatibility(req: Request) async throws -> SPIRECompatibilityReport {
        let spireService = SPIREMigrationService(logger: req.logger)
        return spireService.checkSPIRECompatibility()
    }
}

/// Request structure for certificate validation
struct CertificateValidationRequest: Content {
    let certificatePEM: String
}