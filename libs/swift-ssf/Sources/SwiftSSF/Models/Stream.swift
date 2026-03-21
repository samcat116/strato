import Foundation

/// Event Stream configuration and metadata
public struct EventStream: Codable, Sendable {
    /// Stream identifier
    public let id: String
    
    /// Issuer URL - identifies the transmitter
    public let iss: URL
    
    /// Audience - identifies the intended receivers
    public let aud: [String]
    
    /// Events requested in this stream
    public let events_requested: [String]
    
    /// Events supported by the transmitter
    public let events_supported: [String]?
    
    /// Event delivery configuration
    public let delivery: DeliveryConfiguration
    
    /// Stream status
    public let status: StreamStatus
    
    /// Description of the stream
    public let description: String?
    
    /// When the stream was created
    public let created_at: Date?
    
    /// When the stream was last updated
    public let updated_at: Date?
    
    public init(
        id: String,
        iss: URL,
        aud: [String],
        events_requested: [String],
        events_supported: [String]? = nil,
        delivery: DeliveryConfiguration,
        status: StreamStatus = .enabled,
        description: String? = nil,
        created_at: Date? = nil,
        updated_at: Date? = nil
    ) {
        self.id = id
        self.iss = iss
        self.aud = aud
        self.events_requested = events_requested
        self.events_supported = events_supported
        self.delivery = delivery
        self.status = status
        self.description = description
        self.created_at = created_at
        self.updated_at = updated_at
    }
}

/// Event delivery configuration
public struct DeliveryConfiguration: Codable, Sendable {
    /// Delivery method (push or poll)
    public let method: DeliveryMethod
    
    /// Endpoint URL for push delivery or poll endpoint
    public let endpoint_url: URL
    
    /// Authorization header for push delivery
    public let authorization_header: String?
    
    /// Additional delivery configuration
    public let config: [String: AnyCodable]?
    
    public init(
        method: DeliveryMethod,
        endpoint_url: URL,
        authorization_header: String? = nil,
        config: [String: AnyCodable]? = nil
    ) {
        self.method = method
        self.endpoint_url = endpoint_url
        self.authorization_header = authorization_header
        self.config = config
    }
}

/// Event delivery methods
public enum DeliveryMethod: String, Codable, CaseIterable, Sendable {
    /// Push-based delivery (webhooks)
    case push = "urn:ietf:rfc:8935"
    
    /// Poll-based delivery
    case poll = "urn:ietf:rfc:8936"
}

/// Stream status
public enum StreamStatus: String, Codable, CaseIterable, Sendable {
    /// Stream is enabled and delivering events
    case enabled
    
    /// Stream is paused (not delivering events)
    case paused
    
    /// Stream is disabled
    case disabled
    
    /// Stream is being configured
    case configuring
}

/// Stream creation request
public struct CreateStreamRequest: Codable, Sendable {
    /// Audience - who this stream is for
    public let aud: [String]
    
    /// Events requested
    public let events_requested: [String]
    
    /// Delivery configuration
    public let delivery: DeliveryConfiguration
    
    /// Optional description
    public let description: String?
    
    public init(
        aud: [String],
        events_requested: [String],
        delivery: DeliveryConfiguration,
        description: String? = nil
    ) {
        self.aud = aud
        self.events_requested = events_requested
        self.delivery = delivery
        self.description = description
    }
}

/// Stream update request
public struct UpdateStreamRequest: Codable, Sendable {
    /// Events requested (optional update)
    public let events_requested: [String]?
    
    /// Delivery configuration (optional update)
    public let delivery: DeliveryConfiguration?
    
    /// Stream status (optional update)
    public let status: StreamStatus?
    
    /// Description (optional update)
    public let description: String?
    
    public init(
        events_requested: [String]? = nil,
        delivery: DeliveryConfiguration? = nil,
        status: StreamStatus? = nil,
        description: String? = nil
    ) {
        self.events_requested = events_requested
        self.delivery = delivery
        self.status = status
        self.description = description
    }
}

/// Subject management for streams
public struct StreamSubject: Codable, Sendable {
    /// Subject identifier
    public let subject: SubjectIdentifier
    
    /// Whether the subject is active in the stream
    public let active: Bool
    
    /// When the subject was added
    public let added_at: Date?
    
    public init(subject: SubjectIdentifier, active: Bool = true, added_at: Date? = nil) {
        self.subject = subject
        self.active = active
        self.added_at = added_at
    }
}

/// Add subject request
public struct AddSubjectRequest: Codable, Sendable {
    /// Subject to add
    public let subject: SubjectIdentifier
    
    public init(subject: SubjectIdentifier) {
        self.subject = subject
    }
}

/// Remove subject request
public struct RemoveSubjectRequest: Codable, Sendable {
    /// Subject to remove
    public let subject: SubjectIdentifier
    
    public init(subject: SubjectIdentifier) {
        self.subject = subject
    }
}

/// Stream verification request
public struct VerificationRequest: Codable, Sendable {
    /// Optional state parameter for verification
    public let state: String?
    
    public init(state: String? = nil) {
        self.state = state
    }
}

/// Stream verification response
public struct VerificationResponse: Codable, Sendable {
    /// Verification status
    public let status: VerificationStatus
    
    /// Optional verification details
    public let details: String?
    
    public init(status: VerificationStatus, details: String? = nil) {
        self.status = status
        self.details = details
    }
}

/// Verification status
public enum VerificationStatus: String, Codable, CaseIterable, Sendable {
    /// Verification successful
    case verified
    
    /// Verification failed
    case failed
    
    /// Verification pending
    case pending
}