import Foundation
import Vapor

protocol SpiceDBServiceProtocol {
    func checkPermission(subject: String, permission: String, resource: String, resourceId: String) async throws -> Bool
    func writeRelationship(entity: String, entityId: String, relation: String, subject: String, subjectId: String) async throws
    func deleteRelationship(entity: String, entityId: String, relation: String, subject: String, subjectId: String) async throws
    func addUserToGroup(userID: String, groupID: String) async throws
    func removeUserFromGroup(userID: String, groupID: String) async throws
    func addGroupToProject(groupID: String, projectID: String, role: GroupProjectRole) async throws
    func removeGroupFromProject(groupID: String, projectID: String, role: GroupProjectRole) async throws
    func checkGroupBasedPermission(userID: String, permission: String, resource: String, resourceId: String) async throws -> Bool
}

struct SpiceDBService: SpiceDBServiceProtocol {
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

        // Normalize UUIDs to uppercase for SpiceDB consistency
        let normalizedSubject = subject.uppercased()
        let normalizedResourceId = resourceId.uppercased()

        let payload = CheckPermissionRequest(
            consistency: Consistency(fullyConsistent: true),
            resource: ObjectReference(
                objectType: resource,
                objectId: normalizedResourceId
            ),
            permission: permission,
            subject: SubjectReference(
                object: ObjectReference(
                    objectType: "user",
                    objectId: normalizedSubject
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

        // Normalize UUIDs to uppercase for SpiceDB consistency
        let normalizedEntityId = entityId.uppercased()
        let normalizedSubjectId = subjectId.uppercased()

        let payload = WriteRelationshipsRequest(
            updates: [
                RelationshipUpdate(
                    operation: .create,
                    relationship: Relationship(
                        resource: ObjectReference(
                            objectType: entity,
                            objectId: normalizedEntityId
                        ),
                        relation: relation,
                        subject: SubjectReference(
                            object: ObjectReference(
                                objectType: subject,
                                objectId: normalizedSubjectId
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

        // Normalize UUIDs to uppercase for SpiceDB consistency
        let normalizedEntityId = entityId.uppercased()
        let normalizedSubjectId = subjectId.uppercased()

        let payload = WriteRelationshipsRequest(
            updates: [
                RelationshipUpdate(
                    operation: .delete,
                    relationship: Relationship(
                        resource: ObjectReference(
                            objectType: entity,
                            objectId: normalizedEntityId
                        ),
                        relation: relation,
                        subject: SubjectReference(
                            object: ObjectReference(
                                objectType: subject,
                                objectId: normalizedSubjectId
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

// MARK: - Group Helper Methods

extension SpiceDBService {
    /// Add a user to a group
    func addUserToGroup(userID: String, groupID: String) async throws {
        try await writeRelationship(
            entity: "group",
            entityId: groupID,
            relation: "member",
            subject: "user",
            subjectId: userID
        )
    }

    /// Remove a user from a group
    func removeUserFromGroup(userID: String, groupID: String) async throws {
        try await deleteRelationship(
            entity: "group",
            entityId: groupID,
            relation: "member",
            subject: "user",
            subjectId: userID
        )
    }

    /// Add a group to a project with specific role
    func addGroupToProject(groupID: String, projectID: String, role: GroupProjectRole) async throws {
        try await writeRelationship(
            entity: "project",
            entityId: projectID,
            relation: role.rawValue,
            subject: "group",
            subjectId: groupID
        )
    }

    /// Remove a group from a project
    func removeGroupFromProject(groupID: String, projectID: String, role: GroupProjectRole) async throws {
        try await deleteRelationship(
            entity: "project",
            entityId: projectID,
            relation: role.rawValue,
            subject: "group",
            subjectId: groupID
        )
    }

    /// Check if a user has permission through group membership
    func checkGroupBasedPermission(
        userID: String,
        permission: String,
        resource: String,
        resourceId: String
    ) async throws -> Bool {
        // SpiceDB will automatically check group-based permissions
        // through the schema definitions we created
        return try await checkPermission(
            subject: userID,
            permission: permission,
            resource: resource,
            resourceId: resourceId
        )
    }
}

enum GroupProjectRole: String, Content {
    case admin = "group_admin"
    case member = "group_member"
    case viewer = "group_viewer"
}

// MARK: - Errors

enum SpiceDBError: Error, Sendable {
    case permissionCheckFailed(HTTPStatus)
    case schemaWriteFailed(HTTPStatus)
    case relationshipWriteFailed(HTTPStatus)
    case relationshipDeleteFailed(HTTPStatus)
    case invalidConfiguration
}

// MARK: - Application Extension

// MARK: - Mock Implementation for Testing

struct MockSpiceDBService: SpiceDBServiceProtocol {
    var checkPermissionResult: Bool = true

    func checkPermission(subject: String, permission: String, resource: String, resourceId: String) async throws -> Bool {
        return checkPermissionResult
    }

    func writeRelationship(entity: String, entityId: String, relation: String, subject: String, subjectId: String) async throws {
        // Mock implementation - do nothing
    }

    func deleteRelationship(entity: String, entityId: String, relation: String, subject: String, subjectId: String) async throws {
        // Mock implementation - do nothing
    }

    func addUserToGroup(userID: String, groupID: String) async throws {
        // Mock implementation - do nothing
    }

    func removeUserFromGroup(userID: String, groupID: String) async throws {
        // Mock implementation - do nothing
    }

    func addGroupToProject(groupID: String, projectID: String, role: GroupProjectRole) async throws {
        // Mock implementation - do nothing
    }

    func removeGroupFromProject(groupID: String, projectID: String, role: GroupProjectRole) async throws {
        // Mock implementation - do nothing
    }

    func checkGroupBasedPermission(userID: String, permission: String, resource: String, resourceId: String) async throws -> Bool {
        return checkPermissionResult
    }
}

extension Application {
    var spicedb: SpiceDBServiceProtocol {
        // In testing mode, use a mock implementation
        if self.environment == .testing {
            return MockSpiceDBService()
        }

        guard let endpoint = Environment.get("SPICEDB_ENDPOINT") else {
            fatalError("SPICEDB_ENDPOINT environment variable is required")
        }
        let presharedKey = Environment.get("SPICEDB_PRESHARED_KEY") ?? "strato-dev-key"
        return SpiceDBService(client: self.client, endpoint: endpoint, presharedKey: presharedKey)
    }
}

extension Request {
    var spicedb: SpiceDBServiceProtocol {
        return self.application.spicedb
    }
}
