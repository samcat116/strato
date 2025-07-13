import Foundation
import Vapor

struct SpiceDBService {
    private let client: Client
    private let endpoint: String
    private let presharedKey: String
    
    init(client: Client, endpoint: String, presharedKey: String = "strato-dev-key") {
        self.client = client
        self.endpoint = endpoint
        self.presharedKey = presharedKey
    }
    
    // MARK: - Permission Check
    
    func checkPermission(
        subject: String,
        permission: String,
        resource: String,
        resourceId: String
    ) async throws -> Bool {
        let url = URI(string: "\(endpoint)/v1/permissions/check")
        
        let payload = CheckPermissionRequest(
            consistency: Consistency(fullyConsistent: true),
            resource: ObjectReference(
                objectType: resource,
                objectId: resourceId
            ),
            permission: permission,
            subject: SubjectReference(
                object: ObjectReference(
                    objectType: "user",
                    objectId: subject
                )
            )
        )
        
        let response = try await client.post(url) { req in
            try req.content.encode(payload)
            req.headers.add(name: .contentType, value: "application/json")
            req.headers.add(name: .authorization, value: "Bearer \(presharedKey)")
        }
        
        guard response.status == .ok else {
            throw SpiceDBError.permissionCheckFailed(response.status)
        }
        
        let result = try response.content.decode(CheckPermissionResponse.self)
        return result.permissionship == .hasPermission
    }
    
    // MARK: - Schema Management
    
    func writeSchema(_ schema: String) async throws {
        let url = URI(string: "\(endpoint)/v1/schemas/write")
        
        let payload = WriteSchemaRequest(schema: schema)
        
        let response = try await client.post(url) { req in
            try req.content.encode(payload)
            req.headers.add(name: .contentType, value: "application/json")
            req.headers.add(name: .authorization, value: "Bearer \(presharedKey)")
        }
        
        guard response.status == .ok else {
            throw SpiceDBError.schemaWriteFailed(response.status)
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
        
        let payload = WriteRelationshipsRequest(
            updates: [
                RelationshipUpdate(
                    operation: .create,
                    relationship: Relationship(
                        resource: ObjectReference(
                            objectType: entity,
                            objectId: entityId
                        ),
                        relation: relation,
                        subject: SubjectReference(
                            object: ObjectReference(
                                objectType: subject,
                                objectId: subjectId
                            )
                        )
                    )
                )
            ]
        )
        
        let response = try await client.post(url) { req in
            try req.content.encode(payload)
            req.headers.add(name: .contentType, value: "application/json")
            req.headers.add(name: .authorization, value: "Bearer \(presharedKey)")
        }
        
        guard response.status == .ok else {
            throw SpiceDBError.relationshipWriteFailed(response.status)
        }
    }
    
    func deleteRelationship(
        entity: String,
        entityId: String,
        relation: String,
        subject: String,
        subjectId: String
    ) async throws {
        let url = URI(string: "\(endpoint)/v1/relationships/write")
        
        let payload = WriteRelationshipsRequest(
            updates: [
                RelationshipUpdate(
                    operation: .delete,
                    relationship: Relationship(
                        resource: ObjectReference(
                            objectType: entity,
                            objectId: entityId
                        ),
                        relation: relation,
                        subject: SubjectReference(
                            object: ObjectReference(
                                objectType: subject,
                                objectId: subjectId
                            )
                        )
                    )
                )
            ]
        )
        
        let response = try await client.post(url) { req in
            try req.content.encode(payload)
            req.headers.add(name: .contentType, value: "application/json")
            req.headers.add(name: .authorization, value: "Bearer \(presharedKey)")
        }
        
        guard response.status == .ok else {
            throw SpiceDBError.relationshipDeleteFailed(response.status)
        }
    }
}

// MARK: - DTOs

struct CheckPermissionRequest: Content {
    let consistency: Consistency
    let resource: ObjectReference
    let permission: String
    let subject: SubjectReference
}

struct Consistency: Content {
    let fullyConsistent: Bool?
    
    init(fullyConsistent: Bool = true) {
        self.fullyConsistent = fullyConsistent
    }
    
    private enum CodingKeys: String, CodingKey {
        case fullyConsistent = "fully_consistent"
    }
}

struct ObjectReference: Content {
    let objectType: String
    let objectId: String
    
    enum CodingKeys: String, CodingKey {
        case objectType = "object_type"
        case objectId = "object_id"
    }
}

struct SubjectReference: Content {
    let object: ObjectReference
}

struct CheckPermissionResponse: Content {
    let checkedAt: ZedToken?
    let permissionship: Permissionship
    
    enum CodingKeys: String, CodingKey {
        case checkedAt = "checked_at"
        case permissionship
    }
}

struct ZedToken: Content {
    let token: String
}

enum Permissionship: String, Content {
    case hasPermission = "PERMISSIONSHIP_HAS_PERMISSION"
    case noPermission = "PERMISSIONSHIP_NO_PERMISSION"
    case conditionalPermission = "PERMISSIONSHIP_CONDITIONAL_PERMISSION"
}

struct WriteSchemaRequest: Content {
    let schema: String
}

struct WriteRelationshipsRequest: Content {
    let updates: [RelationshipUpdate]
}

struct RelationshipUpdate: Content {
    let operation: Operation
    let relationship: Relationship
    
    enum Operation: String, Content {
        case create = "OPERATION_CREATE"
        case delete = "OPERATION_DELETE"
    }
}

struct Relationship: Content {
    let resource: ObjectReference
    let relation: String
    let subject: SubjectReference
}

// MARK: - Errors

enum SpiceDBError: Error {
    case permissionCheckFailed(HTTPStatus)
    case schemaWriteFailed(HTTPStatus)
    case relationshipWriteFailed(HTTPStatus)
    case relationshipDeleteFailed(HTTPStatus)
    case invalidConfiguration
}

// MARK: - Application Extension

extension Application {
    var spicedb: SpiceDBService {
        guard let endpoint = Environment.get("SPICEDB_ENDPOINT") else {
            fatalError("SPICEDB_ENDPOINT environment variable is required")
        }
        let presharedKey = Environment.get("SPICEDB_PRESHARED_KEY") ?? "strato-dev-key"
        return SpiceDBService(client: self.client, endpoint: endpoint, presharedKey: presharedKey)
    }
}

extension Request {
    var spicedb: SpiceDBService {
        return self.application.spicedb
    }
}