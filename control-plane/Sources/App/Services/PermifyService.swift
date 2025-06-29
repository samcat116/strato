import Foundation
import Vapor

struct PermifyService {
    private let client: Client
    private let endpoint: String
    private let tenantId: String
    
    init(client: Client, endpoint: String, tenantId: String = "t1") {
        self.client = client
        self.endpoint = endpoint
        self.tenantId = tenantId
    }
    
    // MARK: - Permission Check
    
    func checkPermission(
        subject: String,
        permission: String,
        resource: String,
        resourceId: String,
        context: [String: Any] = [:]
    ) async throws -> Bool {
        let url = URI(string: "\(endpoint)/v1/tenants/\(tenantId)/permissions/check")
        
        // Convert context dictionary to PermissionDataValue
        var convertedContext: [String: PermissionDataValue] = [:]
        for (key, value) in context {
            if let stringValue = value as? String {
                convertedContext[key] = .string(stringValue)
            } else if let intValue = value as? Int {
                convertedContext[key] = .int(intValue)
            } else if let boolValue = value as? Bool {
                convertedContext[key] = .bool(boolValue)
            }
        }
        
        let payload = PermissionCheckRequest(
            metadata: PermissionMetadata(
                snapToken: "",
                schemaVersion: "",
                depth: 20
            ),
            entity: PermissionEntity(
                type: resource,
                id: resourceId
            ),
            permission: permission,
            subject: PermissionSubject(
                type: "user",
                id: subject
            ),
            context: PermissionContext(
                tuples: [],
                attributes: [],
                data: convertedContext
            )
        )
        
        let response = try await client.post(url) { req in
            try req.content.encode(payload)
            req.headers.add(name: .contentType, value: "application/json")
        }
        
        guard response.status == .ok else {
            throw PermifyError.permissionCheckFailed(response.status)
        }
        
        let result = try response.content.decode(PermissionCheckResponse.self)
        return result.can == .CHECK_RESULT_ALLOWED
    }
    
    // MARK: - Schema Management
    
    func writeSchema(_ schema: String) async throws {
        let url = URI(string: "\(endpoint)/v1/tenants/\(tenantId)/schemas/write")
        
        let payload = SchemaWriteRequest(schema: schema)
        
        let response = try await client.post(url) { req in
            try req.content.encode(payload)
            req.headers.add(name: .contentType, value: "application/json")
        }
        
        guard response.status == .ok else {
            throw PermifyError.schemaWriteFailed(response.status)
        }
    }
    
    // MARK: - Relationship Management
    
    func writeRelationship(
        entity: String,
        entityId: String,
        relation: String,
        subject: String,
        subjectId: String
    ) async throws {
        let url = URI(string: "\(endpoint)/v1/tenants/\(tenantId)/relationships/write")
        
        let payload = RelationshipWriteRequest(
            metadata: RelationshipMetadata(
                snapToken: ""
            ),
            tuples: [
                RelationshipTuple(
                    entity: TupleEntity(type: entity, id: entityId),
                    relation: relation,
                    subject: TupleSubject(type: subject, id: subjectId)
                )
            ]
        )
        
        let response = try await client.post(url) { req in
            try req.content.encode(payload)
            req.headers.add(name: .contentType, value: "application/json")
        }
        
        guard response.status == .ok else {
            throw PermifyError.relationshipWriteFailed(response.status)
        }
    }
}

// MARK: - DTOs

struct PermissionCheckRequest: Content {
    let metadata: PermissionMetadata
    let entity: PermissionEntity
    let permission: String
    let subject: PermissionSubject
    let context: PermissionContext
}

struct PermissionMetadata: Content {
    let snapToken: String
    let schemaVersion: String
    let depth: Int
    
    enum CodingKeys: String, CodingKey {
        case snapToken = "snap_token"
        case schemaVersion = "schema_version"
        case depth
    }
}

struct PermissionEntity: Content {
    let type: String
    let id: String
}

struct PermissionSubject: Content {
    let type: String
    let id: String
}

enum PermissionDataValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Value cannot be decoded as String, Int, or Bool")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        }
    }
}

struct PermissionContext: Content {
    let tuples: [String]
    let attributes: [String]
    let data: [String: PermissionDataValue]
    
    init(tuples: [String], attributes: [String], data: [String: PermissionDataValue]) {
        self.tuples = tuples
        self.attributes = attributes
        self.data = data
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tuples = try container.decode([String].self, forKey: .tuples)
        self.attributes = try container.decode([String].self, forKey: .attributes)
        
        // Handle dynamic data decoding
        let dataContainer = try container.nestedContainer(keyedBy: DynamicKey.self, forKey: .data)
        var decodedData: [String: PermissionDataValue] = [:]
        
        for key in dataContainer.allKeys {
            if let value = try? dataContainer.decode(PermissionDataValue.self, forKey: key) {
                decodedData[key.stringValue] = value
            }
        }
        self.data = decodedData
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tuples, forKey: .tuples)
        try container.encode(attributes, forKey: .attributes)
        
        // Handle dynamic data encoding
        var dataContainer = container.nestedContainer(keyedBy: DynamicKey.self, forKey: .data)
        for (key, value) in data {
            let dynamicKey = DynamicKey(stringValue: key)!
            try dataContainer.encode(value, forKey: dynamicKey)
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case tuples, attributes, data
    }
    
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        
        init?(stringValue: String) {
            self.stringValue = stringValue
        }
        
        init?(intValue: Int) {
            return nil
        }
    }
}

struct PermissionCheckResponse: Content {
    let can: PermissionResult
}

enum PermissionResult: String, Content {
    case CHECK_RESULT_ALLOWED = "CHECK_RESULT_ALLOWED"
    case CHECK_RESULT_DENIED = "CHECK_RESULT_DENIED"
}

struct SchemaWriteRequest: Content {
    let schema: String
}

struct RelationshipWriteRequest: Content {
    let metadata: RelationshipMetadata
    let tuples: [RelationshipTuple]
}

struct RelationshipMetadata: Content {
    let snapToken: String
    
    enum CodingKeys: String, CodingKey {
        case snapToken = "snap_token"
    }
}

struct RelationshipTuple: Content {
    let entity: TupleEntity
    let relation: String
    let subject: TupleSubject
}

struct TupleEntity: Content {
    let type: String
    let id: String
}

struct TupleSubject: Content {
    let type: String
    let id: String
}

// MARK: - Errors

enum PermifyError: Error {
    case permissionCheckFailed(HTTPStatus)
    case schemaWriteFailed(HTTPStatus)
    case relationshipWriteFailed(HTTPStatus)
    case invalidConfiguration
}

// MARK: - Application Extension

extension Application {
    var permify: PermifyService {
        guard let endpoint = Environment.get("PERMIFY_ENDPOINT") else {
            fatalError("PERMIFY_ENDPOINT environment variable is required")
        }
        return PermifyService(client: self.client, endpoint: endpoint)
    }
}

extension Request {
    var permify: PermifyService {
        return self.application.permify
    }
}