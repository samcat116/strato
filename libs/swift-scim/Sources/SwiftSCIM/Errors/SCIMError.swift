import Foundation

/// SCIM error response
public struct SCIMErrorResponse: Codable, Sendable {
    public let schemas: [String]
    public let detail: String?
    public let status: String
    public let scimType: String?
    
    public init(
        detail: String? = nil,
        status: String,
        scimType: String? = nil
    ) {
        self.schemas = ["urn:ietf:params:scim:api:messages:2.0:Error"]
        self.detail = detail
        self.status = status
        self.scimType = scimType
    }
}

/// Errors that can occur during SCIM operations
public enum SCIMClientError: Error, Sendable {
    /// Network-related errors
    case networkError(Error)
    
    /// Invalid URL
    case invalidURL(String)
    
    /// Authentication failed
    case authenticationFailed
    
    /// SCIM server returned an error
    case scimError(SCIMErrorResponse)
    
    /// HTTP error with status code
    case httpError(statusCode: Int, data: Data?)
    
    /// JSON decoding failed
    case decodingError(Error)
    
    /// JSON encoding failed
    case encodingError(Error)
    
    /// Invalid request parameters
    case invalidRequest(String)
    
    /// Resource not found
    case resourceNotFound
    
    /// Resource conflict (already exists)
    case resourceConflict
    
    /// Permission denied
    case permissionDenied
    
    /// Rate limit exceeded
    case rateLimitExceeded
    
    /// Server error
    case serverError
    
    /// Unknown error
    case unknown(String)
}

extension SCIMClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .authenticationFailed:
            return "Authentication failed"
        case .scimError(let response):
            return "SCIM error: \(response.detail ?? "Unknown error")"
        case .httpError(let statusCode, _):
            return "HTTP error: \(statusCode)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .encodingError(let error):
            return "Encoding error: \(error.localizedDescription)"
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        case .resourceNotFound:
            return "Resource not found"
        case .resourceConflict:
            return "Resource conflict"
        case .permissionDenied:
            return "Permission denied"
        case .rateLimitExceeded:
            return "Rate limit exceeded"
        case .serverError:
            return "Server error"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }
}

/// SCIM error types as defined in the specification
public enum SCIMErrorType: String, CaseIterable, Sendable {
    case invalidFilter
    case tooMany
    case uniqueness
    case mutability
    case invalidSyntax
    case invalidPath
    case noTarget
    case invalidValue
    case invalidVers
    case sensitive
}