import Foundation
import Vapor

protocol SpiceDBServiceProtocol {
    func readSchema() async throws -> String?
    func writeSchema(_ schema: String) async throws
    func checkPermission(subject: String, permission: String, resource: String, resourceId: String) async throws -> Bool
    func writeRelationship(entity: String, entityId: String, relation: String, subject: String, subjectId: String)
        async throws
    func deleteRelationship(entity: String, entityId: String, relation: String, subject: String, subjectId: String)
        async throws
    func addUserToGroup(userID: String, groupID: String) async throws
    func removeUserFromGroup(userID: String, groupID: String) async throws
    func addGroupToProject(groupID: String, projectID: String, role: GroupProjectRole) async throws
    func removeGroupFromProject(groupID: String, projectID: String, role: GroupProjectRole) async throws
    func checkGroupBasedPermission(userID: String, permission: String, resource: String, resourceId: String)
        async throws -> Bool
}

struct SpiceDBService: SpiceDBServiceProtocol {
    private let client: Client
    private let endpoint: String
    private let presharedKey: String

    init(client: Client, endpoint: String, presharedKey: String) {
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

    /// Returns the currently loaded schema, or nil if SpiceDB has no schema yet
    /// (a fresh in-memory datastore).
    func readSchema() async throws -> String? {
        let url = URI(string: "\(endpoint)/v1/schema/read")

        let response = try await client.post(url) { req in
            req.headers.add(name: .contentType, value: "application/json")
            req.headers.add(name: .authorization, value: "Bearer \(presharedKey)")
            req.body = ByteBuffer(string: "{}")
        }

        if response.status == .notFound {
            return nil
        }

        guard response.status == .ok else {
            throw SpiceDBError.schemaReadFailed(response.status)
        }

        let result = try response.content.decode(ReadSchemaResponse.self)
        return result.schemaText
    }

    func writeSchema(_ schema: String) async throws {
        let url = URI(string: "\(endpoint)/v1/schema/write")

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

struct ReadSchemaResponse: Content {
    let schemaText: String
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
    case schemaReadFailed(HTTPStatus)
    case schemaWriteFailed(HTTPStatus)
    case relationshipWriteFailed(HTTPStatus)
    case relationshipDeleteFailed(HTTPStatus)
    case invalidConfiguration
}

// MARK: - Application Extension

// MARK: - Mock Implementation for Testing

/// Records the relationship writes a `MockSpiceDBService` receives so tests can
/// assert on what would have been written to SpiceDB (which is stubbed out in the
/// testing environment). Install one via `Application.spicedbMockRecorder`.
actor SpiceDBMockRecorder {
    struct RelationshipWrite: Sendable, Equatable {
        let entity: String
        let entityId: String
        let relation: String
        let subject: String
        let subjectId: String
    }

    private(set) var writes: [RelationshipWrite] = []

    func record(_ write: RelationshipWrite) {
        writes.append(write)
    }
}

struct MockSpiceDBService: SpiceDBServiceProtocol {
    var checkPermissionResult: Bool = true
    /// Resource types (e.g. "image") whose permission checks are denied even
    /// when `checkPermissionResult` is true, so tests can withhold access to
    /// one resource while the rest of a handler's checks still pass.
    var deniedResources: Set<String> = []
    var recorder: SpiceDBMockRecorder?

    func readSchema() async throws -> String? {
        return "mock schema"
    }

    func writeSchema(_ schema: String) async throws {
        // Mock implementation - do nothing
    }

    func checkPermission(subject: String, permission: String, resource: String, resourceId: String) async throws -> Bool
    {
        return checkPermissionResult && !deniedResources.contains(resource)
    }

    func writeRelationship(entity: String, entityId: String, relation: String, subject: String, subjectId: String)
        async throws
    {
        await recorder?.record(
            SpiceDBMockRecorder.RelationshipWrite(
                entity: entity,
                entityId: entityId,
                relation: relation,
                subject: subject,
                subjectId: subjectId
            )
        )
    }

    func deleteRelationship(entity: String, entityId: String, relation: String, subject: String, subjectId: String)
        async throws
    {
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

    func checkGroupBasedPermission(userID: String, permission: String, resource: String, resourceId: String)
        async throws -> Bool
    {
        return checkPermissionResult && !deniedResources.contains(resource)
    }
}

extension Application {
    /// Storage key for overriding the testing SpiceDB mock's permission verdict.
    private struct SpiceDBMockAllowsKey: StorageKey {
        typealias Value = Bool
    }

    /// In testing mode, controls whether the mock SpiceDB grants permission.
    /// Defaults to `true` so existing tests keep passing; set to `false` to
    /// exercise authorization-denied paths.
    var spicedbMockAllows: Bool {
        get { storage[SpiceDBMockAllowsKey.self] ?? true }
        set { storage[SpiceDBMockAllowsKey.self] = newValue }
    }

    /// Storage key for the testing SpiceDB mock's per-resource-type denials.
    private struct SpiceDBMockDeniedResourcesKey: StorageKey {
        typealias Value = Set<String>
    }

    /// In testing mode, resource types (e.g. "image") the mock SpiceDB denies
    /// even while `spicedbMockAllows` is true. Lets tests withhold one
    /// permission (say, image read) while a handler's other checks (say,
    /// project create_volume) still pass. Empty by default.
    var spicedbMockDeniedResources: Set<String> {
        get { storage[SpiceDBMockDeniedResourcesKey.self] ?? [] }
        set { storage[SpiceDBMockDeniedResourcesKey.self] = newValue }
    }

    /// Storage key for the testing SpiceDB mock's relationship-write recorder.
    private struct SpiceDBMockRecorderKey: StorageKey {
        typealias Value = SpiceDBMockRecorder
    }

    /// In testing mode, an optional recorder that captures the relationship writes
    /// sent to the mock SpiceDB so tests can assert on them. Unset by default.
    var spicedbMockRecorder: SpiceDBMockRecorder? {
        get { storage[SpiceDBMockRecorderKey.self] }
        set { storage[SpiceDBMockRecorderKey.self] = newValue }
    }

    /// The SpiceDB service, constructed from the required environment configuration.
    ///
    /// Throws rather than calling `fatalError` when configuration is missing: this
    /// getter is reached on every authorized request, so a crash here would take
    /// down a live server. `configure` validates the same variables at startup
    /// (see `validateSpiceDBConfiguration`) so a misconfiguration fails fast at
    /// boot rather than on the first request.
    var spicedb: SpiceDBServiceProtocol {
        get throws {
            // In testing mode, use a mock implementation
            if self.environment == .testing {
                return MockSpiceDBService(
                    checkPermissionResult: spicedbMockAllows,
                    deniedResources: spicedbMockDeniedResources,
                    recorder: spicedbMockRecorder
                )
            }

            guard let endpoint = Environment.get("SPICEDB_ENDPOINT") else {
                throw Abort(.internalServerError, reason: "SPICEDB_ENDPOINT environment variable is required")
            }
            // Require the preshared key to be provided explicitly. There is no
            // in-code fallback: a hardcoded default would ship a known secret that
            // authenticates against SpiceDB in any deployment that forgets to set
            // this variable.
            guard let presharedKey = Environment.get("SPICEDB_PRESHARED_KEY"),
                !presharedKey.isEmpty
            else {
                throw Abort(
                    .internalServerError,
                    reason: "SPICEDB_PRESHARED_KEY environment variable is required and must not be empty"
                )
            }
            return SpiceDBService(client: self.client, endpoint: endpoint, presharedKey: presharedKey)
        }
    }

    /// Validate that the required SpiceDB environment configuration is present so
    /// that a missing variable fails the boot rather than the first request.
    func validateSpiceDBConfiguration() throws {
        _ = try self.spicedb
    }
}

extension Request {
    var spicedb: SpiceDBServiceProtocol {
        get throws { try self.application.spicedb }
    }
}
