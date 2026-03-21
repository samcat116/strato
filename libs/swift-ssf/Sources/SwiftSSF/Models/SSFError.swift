import Foundation

/// Errors that can occur in SSF operations
public enum SSFError: Error, LocalizedError, Sendable {
    /// Invalid JWT format or structure
    case invalidJWT(String)
    
    /// JWT signature verification failed
    case signatureVerificationFailed
    
    /// JWT has expired
    case tokenExpired
    
    /// Invalid issuer
    case invalidIssuer(expected: String, actual: String)
    
    /// Invalid audience
    case invalidAudience(expected: [String], actual: [String]?)
    
    /// Network error occurred
    case networkError(Error)
    
    /// HTTP error with status code
    case httpError(statusCode: Int, message: String?)
    
    /// JSON parsing error
    case jsonParsingError(Error)
    
    /// Missing required configuration
    case missingConfiguration(String)
    
    /// Invalid stream configuration
    case invalidStreamConfiguration(String)
    
    /// Authentication failed
    case authenticationFailed(String)
    
    /// Authorization failed
    case authorizationFailed(String)
    
    /// Server error
    case serverError(String)
    
    /// Stream not found
    case streamNotFound(String)
    
    /// Subject not found
    case subjectNotFound(String)
    
    /// Event parsing error
    case eventParsingError(String)
    
    /// Unsupported event type
    case unsupportedEventType(String)
    
    /// Configuration error
    case configurationError(String)
    
    /// Connection timeout
    case connectionTimeout
    
    /// Unknown error
    case unknown(Error)
    
    public var errorDescription: String? {
        switch self {
        case .invalidJWT(let message):
            return "Invalid JWT: \(message)"
        case .signatureVerificationFailed:
            return "JWT signature verification failed"
        case .tokenExpired:
            return "JWT token has expired"
        case .invalidIssuer(let expected, let actual):
            return "Invalid issuer. Expected: \(expected), Actual: \(actual)"
        case .invalidAudience(let expected, let actual):
            return "Invalid audience. Expected: \(expected), Actual: \(actual?.description ?? "nil")"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .httpError(let statusCode, let message):
            return "HTTP error \(statusCode): \(message ?? "Unknown error")"
        case .jsonParsingError(let error):
            return "JSON parsing error: \(error.localizedDescription)"
        case .missingConfiguration(let field):
            return "Missing required configuration: \(field)"
        case .invalidStreamConfiguration(let message):
            return "Invalid stream configuration: \(message)"
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .authorizationFailed(let message):
            return "Authorization failed: \(message)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .streamNotFound(let id):
            return "Stream not found: \(id)"
        case .subjectNotFound(let id):
            return "Subject not found: \(id)"
        case .eventParsingError(let message):
            return "Event parsing error: \(message)"
        case .unsupportedEventType(let type):
            return "Unsupported event type: \(type)"
        case .configurationError(let message):
            return "Configuration error: \(message)"
        case .connectionTimeout:
            return "Connection timeout"
        case .unknown(let error):
            return "Unknown error: \(error.localizedDescription)"
        }
    }
}

/// HTTP response errors from SSF transmitters
public struct SSFHTTPError: Codable, Sendable {
    /// Error code
    public let error: String
    
    /// Human-readable error description
    public let error_description: String?
    
    /// Additional error details
    public let details: [String: AnyCodable]?
    
    public init(error: String, error_description: String? = nil, details: [String: AnyCodable]? = nil) {
        self.error = error
        self.error_description = error_description
        self.details = details
    }
}

/// Standard SSF error codes
public enum SSFErrorCode: String, CaseIterable, Sendable {
    /// Invalid request
    case invalidRequest = "invalid_request"
    
    /// Unauthorized
    case unauthorized = "unauthorized"
    
    /// Access denied
    case accessDenied = "access_denied"
    
    /// Invalid client
    case invalidClient = "invalid_client"
    
    /// Invalid grant
    case invalidGrant = "invalid_grant"
    
    /// Unsupported grant type
    case unsupportedGrantType = "unsupported_grant_type"
    
    /// Invalid scope
    case invalidScope = "invalid_scope"
    
    /// Server error
    case serverError = "server_error"
    
    /// Temporarily unavailable
    case temporarilyUnavailable = "temporarily_unavailable"
    
    /// Stream not found
    case streamNotFound = "stream_not_found"
    
    /// Subject not found
    case subjectNotFound = "subject_not_found"
    
    /// Invalid subject
    case invalidSubject = "invalid_subject"
    
    /// Verification failed
    case verificationFailed = "verification_failed"
    
    /// Rate limited
    case rateLimited = "rate_limited"
}