import Foundation
import Vapor

struct PermifyService {
    private let client: Client
    private let endpoint: String
    
    init(client: Client, endpoint: String) {
        self.client = client
        self.endpoint = endpoint
    }
    
    // MARK: - Permission Check
    
    func checkPermission(
        subject: String,
        permission: String,
        resource: String,
        resourceId: String,
        context: [String: Any] = [:]
    ) async throws -> Bool {
        let url = URI(string: "\(endpoint)/v1/permissions/check")
        
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
                data: context
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
        return result.can == .RESULT_ALLOWED
    }
    
    // MARK: - Schema Management
    
    func writeSchema(_ schema: String) async throws {
        let url = URI(string: "\(endpoint)/v1/schemas/write")
        
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
        let url = URI(string: "\(endpoint)/v1/relationships/write")
        
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

struct PermissionContext: Content {
    let tuples: [String]
    let attributes: [String]
    let data: [String: Any]
    
    init(tuples: [String], attributes: [String], data: [String: Any]) {
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
        var decodedData: [String: Any] = [:]
        
        for key in dataContainer.allKeys {
            if let stringValue = try? dataContainer.decode(String.self, forKey: key) {
                decodedData[key.stringValue] = stringValue
            } else if let intValue = try? dataContainer.decode(Int.self, forKey: key) {
                decodedData[key.stringValue] = intValue
            } else if let boolValue = try? dataContainer.decode(Bool.self, forKey: key) {
                decodedData[key.stringValue] = boolValue
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
            if let stringValue = value as? String {
                try dataContainer.encode(stringValue, forKey: dynamicKey)
            } else if let intValue = value as? Int {
                try dataContainer.encode(intValue, forKey: dynamicKey)
            } else if let boolValue = value as? Bool {
                try dataContainer.encode(boolValue, forKey: dynamicKey)
            }
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
    case RESULT_ALLOWED = "RESULT_ALLOWED"
    case RESULT_DENIED = "RESULT_DENIED"
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