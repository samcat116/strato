import Foundation

/// SCIM Bulk request
public struct SCIMBulkRequest: Codable, Sendable {
    public let schemas: [String]
    public let Operations: [SCIMBulkOperation]
    public let failOnErrors: Int?
    
    public init(operations: [SCIMBulkOperation], failOnErrors: Int? = nil) {
        self.schemas = ["urn:ietf:params:scim:api:messages:2.0:BulkRequest"]
        self.Operations = operations
        self.failOnErrors = failOnErrors
    }
}

/// SCIM Bulk operation
public struct SCIMBulkOperation: Codable, Sendable {
    public let method: String
    public let bulkId: String?
    public let path: String
    public let data: SCIMBulkOperationData?
    
    public init(method: String, bulkId: String? = nil, path: String, data: SCIMBulkOperationData? = nil) {
        self.method = method
        self.bulkId = bulkId
        self.path = path
        self.data = data
    }
}

/// SCIM Bulk operation data
public enum SCIMBulkOperationData: Codable, Sendable {
    case user(SCIMUser)
    case group(SCIMGroup)
    case patch(SCIMPatchRequest)
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        // Try to decode as different types
        if let user = try? container.decode(SCIMUser.self) {
            self = .user(user)
        } else if let group = try? container.decode(SCIMGroup.self) {
            self = .group(group)
        } else if let patch = try? container.decode(SCIMPatchRequest.self) {
            self = .patch(patch)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode bulk operation data")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .user(let user):
            try container.encode(user)
        case .group(let group):
            try container.encode(group)
        case .patch(let patch):
            try container.encode(patch)
        }
    }
}

/// SCIM Bulk response
public struct SCIMBulkResponse: Codable, Sendable {
    public let schemas: [String]
    public let Operations: [SCIMBulkResponseOperation]
}

/// SCIM Bulk response operation
public struct SCIMBulkResponseOperation: Codable, Sendable {
    public let bulkId: String?
    public let method: String?
    public let location: String?
    public let status: String
    public let response: SCIMBulkOperationData?
}

/// SCIM Service Provider Configuration
public struct SCIMServiceProviderConfig: Codable, Sendable {
    public let schemas: [String]
    public let patch: SCIMFeatureConfig
    public let bulk: SCIMBulkConfig
    public let filter: SCIMFilterConfig
    public let changePassword: SCIMFeatureConfig
    public let sort: SCIMFeatureConfig
    public let etag: SCIMFeatureConfig
    public let authenticationSchemes: [SCIMAuthenticationScheme]
    public let meta: SCIMResourceMeta?
    
    public init(
        patch: SCIMFeatureConfig,
        bulk: SCIMBulkConfig,
        filter: SCIMFilterConfig,
        changePassword: SCIMFeatureConfig,
        sort: SCIMFeatureConfig,
        etag: SCIMFeatureConfig,
        authenticationSchemes: [SCIMAuthenticationScheme],
        meta: SCIMResourceMeta? = nil
    ) {
        self.schemas = ["urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"]
        self.patch = patch
        self.bulk = bulk
        self.filter = filter
        self.changePassword = changePassword
        self.sort = sort
        self.etag = etag
        self.authenticationSchemes = authenticationSchemes
        self.meta = meta
    }
}

/// SCIM Feature configuration
public struct SCIMFeatureConfig: Codable, Sendable {
    public let supported: Bool
    
    public init(supported: Bool) {
        self.supported = supported
    }
}

/// SCIM Bulk configuration
public struct SCIMBulkConfig: Codable, Sendable {
    public let supported: Bool
    public let maxOperations: Int?
    public let maxPayloadSize: Int?
    
    public init(supported: Bool, maxOperations: Int? = nil, maxPayloadSize: Int? = nil) {
        self.supported = supported
        self.maxOperations = maxOperations
        self.maxPayloadSize = maxPayloadSize
    }
}

/// SCIM Filter configuration
public struct SCIMFilterConfig: Codable, Sendable {
    public let supported: Bool
    public let maxResults: Int?
    
    public init(supported: Bool, maxResults: Int? = nil) {
        self.supported = supported
        self.maxResults = maxResults
    }
}

/// SCIM Authentication scheme
public struct SCIMAuthenticationScheme: Codable, Sendable {
    public let type: String
    public let name: String
    public let description: String?
    public let specUri: String?
    public let documentationUri: String?
    
    public init(
        type: String,
        name: String,
        description: String? = nil,
        specUri: String? = nil,
        documentationUri: String? = nil
    ) {
        self.type = type
        self.name = name
        self.description = description
        self.specUri = specUri
        self.documentationUri = documentationUri
    }
}

/// SCIM Resource Type
public struct SCIMResourceType: SCIMResource {
    public let schemas: [String]
    public let id: String?
    public var externalId: String?
    public let meta: SCIMResourceMeta?
    public let name: String
    public let endpoint: String
    public let description: String?
    public let schema: String
    public let schemaExtensions: [SCIMSchemaExtension]?
    
    public init(
        id: String,
        externalId: String? = nil,
        name: String,
        endpoint: String,
        description: String? = nil,
        schema: String,
        schemaExtensions: [SCIMSchemaExtension]? = nil,
        meta: SCIMResourceMeta? = nil
    ) {
        self.schemas = ["urn:ietf:params:scim:schemas:core:2.0:ResourceType"]
        self.id = id
        self.externalId = externalId
        self.name = name
        self.endpoint = endpoint
        self.description = description
        self.schema = schema
        self.schemaExtensions = schemaExtensions
        self.meta = meta
    }
}

/// SCIM Schema Extension
public struct SCIMSchemaExtension: Codable, Sendable {
    public let schema: String
    public let required: Bool
    
    public init(schema: String, required: Bool) {
        self.schema = schema
        self.required = required
    }
}

/// SCIM Schema
public struct SCIMSchema: SCIMResource {
    public let schemas: [String]
    public let id: String?
    public var externalId: String?
    public let meta: SCIMResourceMeta?
    public let name: String
    public let description: String?
    public let attributes: [SCIMSchemaAttribute]
    
    public init(
        id: String,
        externalId: String? = nil,
        name: String,
        description: String? = nil,
        attributes: [SCIMSchemaAttribute],
        meta: SCIMResourceMeta? = nil
    ) {
        self.schemas = ["urn:ietf:params:scim:schemas:core:2.0:Schema"]
        self.id = id
        self.externalId = externalId
        self.name = name
        self.description = description
        self.attributes = attributes
        self.meta = meta
    }
}

/// SCIM Schema Attribute
public struct SCIMSchemaAttribute: Codable, Sendable {
    public let name: String
    public let type: String
    public let multiValued: Bool?
    public let description: String?
    public let required: Bool?
    public let canonicalValues: [String]?
    public let caseExact: Bool?
    public let mutability: String?
    public let returned: String?
    public let uniqueness: String?
    public let subAttributes: [SCIMSchemaAttribute]?
    
    public init(
        name: String,
        type: String,
        multiValued: Bool? = nil,
        description: String? = nil,
        required: Bool? = nil,
        canonicalValues: [String]? = nil,
        caseExact: Bool? = nil,
        mutability: String? = nil,
        returned: String? = nil,
        uniqueness: String? = nil,
        subAttributes: [SCIMSchemaAttribute]? = nil
    ) {
        self.name = name
        self.type = type
        self.multiValued = multiValued
        self.description = description
        self.required = required
        self.canonicalValues = canonicalValues
        self.caseExact = caseExact
        self.mutability = mutability
        self.returned = returned
        self.uniqueness = uniqueness
        self.subAttributes = subAttributes
    }
}