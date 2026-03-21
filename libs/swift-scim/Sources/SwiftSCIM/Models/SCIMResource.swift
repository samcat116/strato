import Foundation

/// Base protocol for all SCIM resources
public protocol SCIMResource: Codable, Sendable {
    /// Unique identifier for the resource
    var id: String? { get }
    
    /// External identifier for the resource
    var externalId: String? { get set }
    
    /// Resource metadata
    var meta: SCIMResourceMeta? { get }
    
    /// Schema URIs
    var schemas: [String] { get }
}

/// Metadata about a SCIM resource
public struct SCIMResourceMeta: Codable, Sendable {
    /// The name of the resource type
    public let resourceType: String?
    
    /// The date/time the resource was created
    public let created: Date?
    
    /// The date/time the resource was last modified
    public let lastModified: Date?
    
    /// The location URI of the resource
    public let location: String?
    
    /// The version of the resource (ETag)
    public let version: String?
    
    public init(
        resourceType: String? = nil,
        created: Date? = nil,
        lastModified: Date? = nil,
        location: String? = nil,
        version: String? = nil
    ) {
        self.resourceType = resourceType
        self.created = created
        self.lastModified = lastModified
        self.location = location
        self.version = version
    }
}

/// Represents a multi-valued attribute in SCIM
public struct SCIMMultiValuedAttribute<T: Codable & Sendable>: Codable, Sendable {
    public let value: T
    public let type: String?
    public let primary: Bool?
    public let display: String?
    
    public init(
        value: T,
        type: String? = nil,
        primary: Bool? = nil,
        display: String? = nil
    ) {
        self.value = value
        self.type = type
        self.primary = primary
        self.display = display
    }
}

/// SCIM list response for paginated results
public struct SCIMListResponse<T: SCIMResource>: Codable, Sendable {
    public let schemas: [String]
    public let totalResults: Int
    public let startIndex: Int?
    public let itemsPerPage: Int?
    public let Resources: [T]
    
    public init(
        totalResults: Int,
        resources: [T],
        startIndex: Int? = nil,
        itemsPerPage: Int? = nil
    ) {
        self.schemas = ["urn:ietf:params:scim:api:messages:2.0:ListResponse"]
        self.totalResults = totalResults
        self.Resources = resources
        self.startIndex = startIndex
        self.itemsPerPage = itemsPerPage
    }
}