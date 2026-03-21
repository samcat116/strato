import Foundation

// MARK: - Search Operations
extension SCIMClient {
    
    /// Perform a cross-resource search using the /.search endpoint
    /// - Parameter searchRequest: The search request parameters
    /// - Returns: Search response containing mixed resource types
    public func search(_ searchRequest: SCIMSearchRequest) async throws -> SCIMSearchResponse {
        return try await post(
            path: ".search",
            body: searchRequest,
            responseType: SCIMSearchResponse.self
        )
    }
    
    /// Search for users using the /.search endpoint
    /// - Parameter searchRequest: The search request parameters
    /// - Returns: List response containing users
    public func searchUsersViaSearchEndpoint(_ searchRequest: SCIMSearchRequest) async throws -> SCIMListResponse<SCIMUser> {
        let response = try await search(searchRequest)
        
        // Convert the generic search response to a typed user response
        let users = try response.Resources.map { resource in
            let data = try encoder.encode(resource)
            return try decoder.decode(SCIMUser.self, from: data)
        }
        
        return SCIMListResponse<SCIMUser>(
            totalResults: response.totalResults,
            resources: users,
            startIndex: response.startIndex,
            itemsPerPage: response.itemsPerPage
        )
    }
    
    /// Search for groups using the /.search endpoint
    /// - Parameter searchRequest: The search request parameters
    /// - Returns: List response containing groups
    public func searchGroupsViaSearchEndpoint(_ searchRequest: SCIMSearchRequest) async throws -> SCIMListResponse<SCIMGroup> {
        let response = try await search(searchRequest)
        
        // Convert the generic search response to a typed group response
        let groups = try response.Resources.map { resource in
            let data = try encoder.encode(resource)
            return try decoder.decode(SCIMGroup.self, from: data)
        }
        
        return SCIMListResponse<SCIMGroup>(
            totalResults: response.totalResults,
            resources: groups,
            startIndex: response.startIndex,
            itemsPerPage: response.itemsPerPage
        )
    }
    
    /// Perform a bulk operation
    /// - Parameter bulkRequest: The bulk request containing multiple operations
    /// - Returns: Bulk response with operation results
    public func bulk(_ bulkRequest: SCIMBulkRequest) async throws -> SCIMBulkResponse {
        return try await post(
            path: "Bulk",
            body: bulkRequest,
            responseType: SCIMBulkResponse.self
        )
    }
    
    /// Get service provider configuration
    /// - Returns: Service provider configuration
    public func getServiceProviderConfig() async throws -> SCIMServiceProviderConfig {
        return try await get(
            path: "ServiceProviderConfig",
            responseType: SCIMServiceProviderConfig.self
        )
    }
    
    /// Get resource types
    /// - Returns: List of supported resource types
    public func getResourceTypes() async throws -> SCIMListResponse<SCIMResourceType> {
        return try await get(
            path: "ResourceTypes",
            responseType: SCIMListResponse<SCIMResourceType>.self
        )
    }
    
    /// Get schemas
    /// - Returns: List of supported schemas
    public func getSchemas() async throws -> SCIMListResponse<SCIMSchema> {
        return try await get(
            path: "Schemas",
            responseType: SCIMListResponse<SCIMSchema>.self
        )
    }
    
    /// Get a specific schema by ID
    /// - Parameter schemaId: The schema ID (URI)
    /// - Returns: The schema definition
    public func getSchema(id schemaId: String) async throws -> SCIMSchema {
        // URL encode the schema ID since it's a URI
        let encodedId = schemaId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? schemaId
        return try await get(
            path: "Schemas/\(encodedId)",
            responseType: SCIMSchema.self
        )
    }
}

/// SCIM search request for the /.search endpoint
public struct SCIMSearchRequest: Codable, Sendable {
    public let schemas: [String]
    public let attributes: [String]?
    public let excludedAttributes: [String]?
    public let filter: String?
    public let sortBy: String?
    public let sortOrder: String?
    public let startIndex: Int?
    public let count: Int?
    
    public init(
        attributes: [String]? = nil,
        excludedAttributes: [String]? = nil,
        filter: String? = nil,
        sortBy: String? = nil,
        sortOrder: String? = nil,
        startIndex: Int? = nil,
        count: Int? = nil
    ) {
        self.schemas = ["urn:ietf:params:scim:api:messages:2.0:SearchRequest"]
        self.attributes = attributes
        self.excludedAttributes = excludedAttributes
        self.filter = filter
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.startIndex = startIndex
        self.count = count
    }
    
    public init(queryParameters: SCIMQueryParameters) {
        self.init(
            attributes: queryParameters.attributes,
            excludedAttributes: queryParameters.excludedAttributes,
            filter: queryParameters.filter?.expression,
            sortBy: queryParameters.sortBy,
            sortOrder: queryParameters.sortOrder?.rawValue,
            startIndex: queryParameters.startIndex,
            count: queryParameters.count
        )
    }
}

/// SCIM search response from the /.search endpoint
public struct SCIMSearchResponse: Codable {
    public let schemas: [String]
    public let totalResults: Int
    public let startIndex: Int?
    public let itemsPerPage: Int?
    public let Resources: [SCIMGenericResource]
}

/// Generic SCIM resource for mixed search results
public struct SCIMGenericResource: Codable {
    public let id: String?
    public let externalId: String?
    public let meta: SCIMResourceMeta?
    public let schemas: [String]
    
    private let additionalProperties: [String: AnyCodable]
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decodeIfPresent(String.self, forKey: .id)
        externalId = try container.decodeIfPresent(String.self, forKey: .externalId)
        meta = try container.decodeIfPresent(SCIMResourceMeta.self, forKey: .meta)
        schemas = try container.decode([String].self, forKey: .schemas)
        
        // Decode all other properties
        let allKeys = container.allKeys
        var additional: [String: AnyCodable] = [:]
        
        for key in allKeys {
            if !CodingKeys.allCases.map(\.rawValue).contains(key.stringValue) {
                additional[key.stringValue] = try container.decode(AnyCodable.self, forKey: key)
            }
        }
        
        additionalProperties = additional
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        
        try container.encodeIfPresent(id, forKey: DynamicCodingKey(stringValue: "id"))
        try container.encodeIfPresent(externalId, forKey: DynamicCodingKey(stringValue: "externalId"))
        try container.encodeIfPresent(meta, forKey: DynamicCodingKey(stringValue: "meta"))
        try container.encode(schemas, forKey: DynamicCodingKey(stringValue: "schemas"))
        
        // Encode additional properties
        for (key, value) in additionalProperties {
            try container.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
    }
    
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, externalId, meta, schemas
    }
}

/// Helper for dynamic coding keys
private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    
    init(stringValue: String) {
        self.stringValue = stringValue
    }
    
    init?(intValue: Int) {
        return nil
    }
}

/// Type-erased codable value
public struct AnyCodable: Codable {
    private let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        if value is NSNull {
            try container.encodeNil()
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let string = value as? String {
            try container.encode(string)
        } else if let array = value as? [Any] {
            try container.encode(array.map(AnyCodable.init))
        } else if let dictionary = value as? [String: Any] {
            try container.encode(dictionary.mapValues(AnyCodable.init))
        } else {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: container.codingPath, debugDescription: "Unsupported type"))
        }
    }
}