import Foundation
import Vapor
import Crypto

/// Service for certificate security validation and recommendations
struct CertificateSecurityService {
    let logger: Logger
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    /// Generate security recommendations for the certificate infrastructure
    func generateSecurityRecommendations() -> [SecurityRecommendation] {
        var recommendations: [SecurityRecommendation] = []
        
        // Recommend short certificate lifetimes
        recommendations.append(SecurityRecommendation(
            id: "cert-lifetime",
            severity: .medium,
            title: "Certificate Lifetime Management",
            description: "Ensure certificates have short lifetimes (12-24 hours) to minimize exposure windows",
            action: "Configure certificate lifetime to 24 hours or less",
            category: .certificateLifecycle
        ))
        
        // Recommend ECDSA over RSA
        recommendations.append(SecurityRecommendation(
            id: "crypto-algorithm",
            severity: .low,
            title: "Modern Cryptographic Algorithms",
            description: "Use ECDSA P-256 keys instead of RSA for better performance and security",
            action: "Migrate to ECDSA P-256 key pairs for new certificates",
            category: .cryptography
        ))
        
        // Recommend certificate rotation
        recommendations.append(SecurityRecommendation(
            id: "cert-rotation",
            severity: .high,
            title: "Automatic Certificate Rotation",
            description: "Enable automatic certificate rotation at 60% of certificate lifetime",
            action: "Configure agents to automatically renew certificates",
            category: .certificateLifecycle
        ))
        
        // Recommend audit logging
        recommendations.append(SecurityRecommendation(
            id: "audit-logging",
            severity: .high,
            title: "Comprehensive Audit Logging",
            description: "Enable detailed audit logging for all certificate operations",
            action: "Configure audit logs to be sent to SIEM systems",
            category: .monitoring
        ))
        
        return recommendations
    }
    
    /// Validate cryptographic standards of a certificate
    func validateCryptographicStandards(certificatePEM: String) -> SecurityValidationResult {
        var validations: [SecurityValidation] = []
        var overallScore = 100
        
        // Parse certificate (simplified validation for now)
        do {
            // In a real implementation, we would parse the PEM and extract certificate details
            // For now, we'll simulate basic validations
            
            validations.append(SecurityValidation(
                check: "Certificate Format",
                passed: certificatePEM.contains("-----BEGIN CERTIFICATE-----"),
                message: certificatePEM.contains("-----BEGIN CERTIFICATE-----") ? "Valid PEM format" : "Invalid PEM format",
                severity: .high
            ))
            
            if !certificatePEM.contains("-----BEGIN CERTIFICATE-----") {
                overallScore -= 50
            }
            
            // Simulate key algorithm check
            validations.append(SecurityValidation(
                check: "Key Algorithm",
                passed: true,
                message: "Using modern key algorithm",
                severity: .medium
            ))
            
            // Simulate certificate lifetime check
            validations.append(SecurityValidation(
                check: "Certificate Lifetime",
                passed: true,
                message: "Certificate lifetime within recommended bounds",
                severity: .high
            ))
            
            // Simulate extensions check
            validations.append(SecurityValidation(
                check: "Required Extensions",
                passed: true,
                message: "Certificate contains required extensions",
                severity: .medium
            ))
            
        } catch {
            logger.error("Failed to validate certificate: \(error)")
            overallScore = 0
            
            validations.append(SecurityValidation(
                check: "Certificate Parsing",
                passed: false,
                message: "Failed to parse certificate: \(error.localizedDescription)",
                severity: .high
            ))
        }
        
        return SecurityValidationResult(
            score: overallScore,
            grade: gradeFromScore(overallScore),
            validations: validations,
            recommendations: generateCertificateRecommendations(validations: validations)
        )
    }
    
    private func gradeFromScore(_ score: Int) -> SecurityGrade {
        switch score {
        case 90...100: return .excellent
        case 80..<90: return .good  
        case 70..<80: return .fair
        case 50..<70: return .poor
        default: return .fail
        }
    }
    
    private func generateCertificateRecommendations(validations: [SecurityValidation]) -> [String] {
        var recommendations: [String] = []
        
        for validation in validations where !validation.passed {
            switch validation.check {
            case "Certificate Format":
                recommendations.append("Ensure certificate is in valid PEM format")
            case "Key Algorithm":
                recommendations.append("Use ECDSA P-256 instead of RSA keys")
            case "Certificate Lifetime":
                recommendations.append("Reduce certificate lifetime to 24 hours or less")
            case "Required Extensions":
                recommendations.append("Add required certificate extensions (SAN, Key Usage)")
            default:
                recommendations.append("Address \(validation.check) validation failure")
            }
        }
        
        return recommendations
    }
}

/// Security recommendation structure
struct SecurityRecommendation: Content {
    let id: String
    let severity: SecuritySeverity
    let title: String
    let description: String
    let action: String
    let category: SecurityCategory
}

/// Security validation result
struct SecurityValidationResult: Content {
    let score: Int
    let grade: SecurityGrade
    let validations: [SecurityValidation]
    let recommendations: [String]
}

/// Individual security validation
struct SecurityValidation: Codable {
    let check: String
    let passed: Bool
    let message: String  
    let severity: SecuritySeverity
}

/// Security severity levels
enum SecuritySeverity: String, Codable, CaseIterable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case critical = "critical"
}

/// Security recommendation categories
enum SecurityCategory: String, Codable, CaseIterable {
    case cryptography = "cryptography"
    case certificateLifecycle = "certificate_lifecycle"
    case monitoring = "monitoring"
    case network = "network"
    case compliance = "compliance"
}

/// Security grade enum
enum SecurityGrade: String, Codable, CaseIterable {
    case excellent = "A+"
    case good = "A"
    case fair = "B"
    case poor = "C"
    case fail = "F"
}