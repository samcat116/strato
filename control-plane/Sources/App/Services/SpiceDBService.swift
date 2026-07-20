import Foundation
import Vapor

// Sendable so callers can use the service inside @Sendable contexts such as
// Fluent transaction closures; both conforming types are value types holding
// only Sendable state.
protocol SpiceDBServiceProtocol: Sendable {
    func readSchema() async throws -> String?
    func writeSchema(_ schema: String) async throws
    func checkPermission(subject: String, permission: String, resource: String, resourceId: String) async throws -> Bool
    func writeRelationship(entity: String, entityId: String, relation: String, subject: String, subjectId: String)
        async throws
    func deleteRelationship(entity: String, entityId: String, relation: String, subject: String, subjectId: String)
        async throws
    func touchRelationships(_ tuples: [RelationshipTuple]) async throws
    func readRelationships(resourceType: String, relation: String?) async throws -> [RelationshipTuple]
    func setOrganizationRole(userID: String, organizationID: String, oldRole: String?, newRole: String) async throws
    func removeOrganizationMember(userID: String, organizationID: String, role: String) async throws
    func addUserToGroup(userID: String, groupID: String) async throws
    func removeUserFromGroup(userID: String, groupID: String) async throws
    func addGroupToProject(groupID: String, projectID: String, role: GroupProjectRole) async throws
    func removeGroupFromProject(groupID: String, projectID: String, role: GroupProjectRole) async throws
    func checkGroupBasedPermission(userID: String, permission: String, resource: String, resourceId: String)
        async throws -> Bool
}

/// A single relationship to write. Used by `touchRelationships` for idempotent
/// batch writes (backfills), where each tuple may or may not already exist.
struct RelationshipTuple: Sendable, Equatable {
    let entity: String
    let entityId: String
    let relation: String
    let subject: String
    let subjectId: String
}

// MARK: - Bulk Permission Checks

/// A single permission question for `checkBulk`. `key` is an opaque client-chosen
/// identifier echoed back in the result map, so the caller can correlate answers
/// without depending on ordering.
struct PermissionQuery: Sendable {
    let key: String
    let permission: String
    let resourceType: String
    let resourceId: String
}

extension SpiceDBServiceProtocol {
    /// Answer several permission questions for one subject, returning a map keyed by
    /// each query's `key`.
    ///
    /// Implemented as sequential `checkPermission` calls: version-agnostic (works
    /// against any SpiceDB) and avoids the Sendable constraints of fanning `self` out
    /// across a task group. Callers cap the batch size (the authorization endpoint
    /// rejects > 50), so the sequential cost is bounded. Can be upgraded to SpiceDB's
    /// native `/v1/permissions/checkbulk` later without changing this signature.
    func checkBulk(subject: String, _ checks: [PermissionQuery]) async throws -> [String: Bool] {
        var results: [String: Bool] = [:]
        results.reserveCapacity(checks.count)
        for check in checks {
            results[check.key] = try await checkPermission(
                subject: subject,
                permission: check.permission,
                resource: check.resourceType,
                resourceId: check.resourceId
            )
        }
        return results
    }
}

// MARK: - Organization Role Helpers

/// Default implementations that keep SpiceDB organization-role tuples consistent.
///
/// A role change must DELETE the old `organization#<oldRole>@user` tuple before
/// writing the new one — otherwise the stale tuple lingers and the user retains the
/// old role's permissions (e.g. a demoted admin keeps admin access). Composing these
/// out of `deleteRelationship`/`writeRelationship` means both the real service and the
/// testing mock get identical, correct behavior.
extension SpiceDBServiceProtocol {
    /// Set a user's organization role, deleting the previous role tuple first.
    ///
    /// Pass `oldRole: nil` when granting a role for the first time (e.g. org create).
    /// A no-op when `oldRole == newRole` (avoids an `OPERATION_CREATE` on an existing
    /// tuple, which SpiceDB rejects as already-exists).
    func setOrganizationRole(
        userID: String,
        organizationID: String,
        oldRole: String?,
        newRole: String
    ) async throws {
        if let oldRole {
            if oldRole == newRole { return }
            try await deleteRelationship(
                entity: "organization",
                entityId: organizationID,
                relation: oldRole,
                subject: "user",
                subjectId: userID
            )
        }
        try await writeRelationship(
            entity: "organization",
            entityId: organizationID,
            relation: newRole,
            subject: "user",
            subjectId: userID
        )
    }

    /// Remove a user's organization membership tuple for the given role.
    func removeOrganizationMember(
        userID: String,
        organizationID: String,
        role: String
    ) async throws {
        try await deleteRelationship(
            entity: "organization",
            entityId: organizationID,
            relation: role,
            subject: "user",
            subjectId: userID
        )
    }

    /// Set a user's project role, deleting the previous role tuple first (same
    /// stale-tuple-avoiding contract as `setOrganizationRole`). Pass `oldRole: nil`
    /// when granting for the first time.
    func setProjectRole(
        userID: String,
        projectID: String,
        oldRole: String?,
        newRole: String
    ) async throws {
        if let oldRole {
            if oldRole == newRole { return }
            try await deleteRelationship(
                entity: "project",
                entityId: projectID,
                relation: oldRole,
                subject: "user",
                subjectId: userID
            )
        }
        try await writeRelationship(
            entity: "project",
            entityId: projectID,
            relation: newRole,
            subject: "user",
            subjectId: userID
        )
    }

    /// Remove a user's project role tuple.
    func removeProjectMember(
        userID: String,
        projectID: String,
        role: String
    ) async throws {
        try await deleteRelationship(
            entity: "project",
            entityId: projectID,
            relation: role,
            subject: "user",
            subjectId: userID
        )
    }
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

    /// Idempotently write many relationships in a few HTTP calls using
    /// OPERATION_TOUCH (create-or-noop), chunked to stay under SpiceDB's
    /// per-request update cap. Used by startup backfills so re-writing tuples that
    /// already exist is cheap and never errors — unlike per-row OPERATION_CREATE.
    func touchRelationships(_ tuples: [RelationshipTuple]) async throws {
        guard !tuples.isEmpty else { return }
        let url = URI(string: "\(endpoint)/v1/relationships/write")
        // SpiceDB caps updates per WriteRelationships request (default 1000); stay well under.
        let chunkSize = 500
        var index = 0
        while index < tuples.count {
            let chunk = tuples[index..<min(index + chunkSize, tuples.count)]
            let payload = WriteRelationshipsRequest(
                updates: chunk.map { tuple in
                    RelationshipUpdate(
                        operation: .touch,
                        relationship: Relationship(
                            resource: ObjectReference(
                                objectType: tuple.entity,
                                objectId: tuple.entityId.uppercased()
                            ),
                            relation: tuple.relation,
                            subject: SubjectReference(
                                object: ObjectReference(
                                    objectType: tuple.subject,
                                    objectId: tuple.subjectId.uppercased()
                                )
                            )
                        )
                    )
                }
            )

            let response = try await client.post(url) { req in
                try req.content.encode(payload)
                req.headers.add(name: .contentType, value: "application/json")
                req.headers.add(name: .authorization, value: "Bearer \(presharedKey)")
            }

            guard response.status == .ok else {
                throw SpiceDBError.relationshipWriteFailed(response.status)
            }
            index += chunkSize
        }
    }

    /// Read every relationship of `resourceType` (optionally narrowed to one
    /// relation). Used by the IAM bindings backfill to export resource-level
    /// `owner`/`viewer`/`editor` tuples, which exist only in SpiceDB.
    ///
    /// The HTTP API streams newline-delimited JSON — one `{"result": …}`
    /// envelope per relationship — so this parses the body line by line.
    /// Vapor's client buffers the whole response before we see it; that is a
    /// deliberate trade-off: the export is scoped per (resource type, relation)
    /// pair and runs once per boot, so response sizes stay modest. Move to
    /// AsyncHTTPClient's chunked body iteration if a deployment ever has enough
    /// tuples of one relation for buffering to matter.
    func readRelationships(resourceType: String, relation: String?) async throws -> [RelationshipTuple] {
        let url = URI(string: "\(endpoint)/v1/relationships/read")

        let payload = ReadRelationshipsRequest(
            consistency: Consistency(fullyConsistent: true),
            relationshipFilter: RelationshipFilter(
                resourceType: resourceType,
                optionalRelation: relation
            )
        )

        let response = try await client.post(url) { req in
            try req.content.encode(payload)
            req.headers.add(name: .contentType, value: "application/json")
            req.headers.add(name: .authorization, value: "Bearer \(presharedKey)")
        }

        guard response.status == .ok else {
            throw SpiceDBError.relationshipReadFailed(response.status)
        }

        guard let body = response.body else { return [] }
        let text = String(buffer: body)
        let decoder = JSONDecoder()
        var tuples: [RelationshipTuple] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            let envelope = try decoder.decode(ReadRelationshipsResponseLine.self, from: data)
            if envelope.error != nil {
                throw SpiceDBError.relationshipReadFailed(.internalServerError)
            }
            guard let relationship = envelope.result?.relationship else { continue }
            tuples.append(
                RelationshipTuple(
                    entity: relationship.resource.objectType,
                    entityId: relationship.resource.objectId,
                    relation: relationship.relation,
                    subject: relationship.subject.object.objectType,
                    subjectId: relationship.subject.object.objectId
                )
            )
        }
        return tuples
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

    /// SpiceDB's grpc-gateway accepts snake_case on input but emits camelCase
    /// on output, and this type is used for both request bodies and response
    /// parsing. Decoding only `object_type` meant every ReadRelationships
    /// response failed to decode, which crashed the control plane at boot once
    /// `RoleBindingBackfill.backfillFromSpiceDB` started running there. Encode
    /// stays snake_case (accepted by every version); decode takes either.
    private enum ResponseCodingKeys: String, CodingKey {
        case objectType
        case objectId
    }

    init(objectType: String, objectId: String) {
        self.objectType = objectType
        self.objectId = objectId
    }

    init(from decoder: Decoder) throws {
        let snakeCase = try decoder.container(keyedBy: CodingKeys.self)
        if let objectType = try snakeCase.decodeIfPresent(String.self, forKey: .objectType),
            let objectId = try snakeCase.decodeIfPresent(String.self, forKey: .objectId)
        {
            self.objectType = objectType
            self.objectId = objectId
            return
        }

        let camelCase = try decoder.container(keyedBy: ResponseCodingKeys.self)
        self.objectType = try camelCase.decode(String.self, forKey: .objectType)
        self.objectId = try camelCase.decode(String.self, forKey: .objectId)
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
        case touch = "OPERATION_TOUCH"
        case delete = "OPERATION_DELETE"
    }
}

struct Relationship: Content {
    let resource: ObjectReference
    let relation: String
    let subject: SubjectReference
}

struct ReadRelationshipsRequest: Content {
    let consistency: Consistency
    let relationshipFilter: RelationshipFilter

    enum CodingKeys: String, CodingKey {
        case consistency
        case relationshipFilter = "relationship_filter"
    }
}

struct RelationshipFilter: Content {
    let resourceType: String
    let optionalRelation: String?

    enum CodingKeys: String, CodingKey {
        case resourceType = "resource_type"
        case optionalRelation = "optional_relation"
    }
}

/// One line of the streamed ReadRelationships response: either a result
/// envelope or a mid-stream error object.
struct ReadRelationshipsResponseLine: Content {
    struct Result: Content {
        let relationship: Relationship?
    }
    let result: Result?
    let error: ErrorBody?

    struct ErrorBody: Content {
        let code: Int?
        let message: String?
    }
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
    case relationshipReadFailed(HTTPStatus)
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
    /// Relationship deletes the mock received, so tests can assert stale tuples are
    /// cleaned up (e.g. the old role is removed on a role change).
    private(set) var deletes: [RelationshipWrite] = []

    func record(_ write: RelationshipWrite) {
        writes.append(write)
    }

    func recordDelete(_ delete: RelationshipWrite) {
        deletes.append(delete)
    }
}

struct MockSpiceDBService: SpiceDBServiceProtocol {
    var checkPermissionResult: Bool = true
    /// Resource types (e.g. "image") whose permission checks are denied even
    /// when `checkPermissionResult` is true, so tests can withhold access to
    /// one resource while the rest of a handler's checks still pass.
    var deniedResources: Set<String> = []
    /// Permission names (e.g. "export") denied even when
    /// `checkPermissionResult` is true, so a test can grant a handler's other
    /// checks on the same resource type while withholding exactly one verb.
    var deniedPermissions: Set<String> = []
    var recorder: SpiceDBMockRecorder?
    /// When true, relationship writes throw, so tests can exercise the
    /// partial-failure paths of flows that pair SQL rows with SpiceDB tuples.
    var writesFail: Bool = false
    /// Canned relationships served by `readRelationships`, so tests can
    /// exercise export-driven flows (the IAM bindings backfill).
    var relationships: [RelationshipTuple] = []

    func readSchema() async throws -> String? {
        return "mock schema"
    }

    func writeSchema(_ schema: String) async throws {
        // Mock implementation - do nothing
    }

    func checkPermission(subject: String, permission: String, resource: String, resourceId: String) async throws -> Bool
    {
        return checkPermissionResult && !deniedResources.contains(resource)
            && !deniedPermissions.contains(permission)
    }

    func writeRelationship(entity: String, entityId: String, relation: String, subject: String, subjectId: String)
        async throws
    {
        if writesFail {
            throw Abort(.internalServerError, reason: "Mock SpiceDB write failure")
        }
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
        await recorder?.recordDelete(
            SpiceDBMockRecorder.RelationshipWrite(
                entity: entity,
                entityId: entityId,
                relation: relation,
                subject: subject,
                subjectId: subjectId
            )
        )
    }

    // The group helpers delegate to write/deleteRelationship so the recorder captures
    // them (tests assert on group grants), mirroring the real service's composition.
    func touchRelationships(_ tuples: [RelationshipTuple]) async throws {
        for tuple in tuples {
            await recorder?.record(
                SpiceDBMockRecorder.RelationshipWrite(
                    entity: tuple.entity,
                    entityId: tuple.entityId,
                    relation: tuple.relation,
                    subject: tuple.subject,
                    subjectId: tuple.subjectId
                )
            )
        }
    }

    func readRelationships(resourceType: String, relation: String?) async throws -> [RelationshipTuple] {
        relationships.filter { tuple in
            tuple.entity == resourceType && (relation == nil || tuple.relation == relation)
        }
    }

    func addUserToGroup(userID: String, groupID: String) async throws {
        try await writeRelationship(
            entity: "group", entityId: groupID, relation: "member", subject: "user", subjectId: userID)
    }

    func removeUserFromGroup(userID: String, groupID: String) async throws {
        try await deleteRelationship(
            entity: "group", entityId: groupID, relation: "member", subject: "user", subjectId: userID)
    }

    func addGroupToProject(groupID: String, projectID: String, role: GroupProjectRole) async throws {
        try await writeRelationship(
            entity: "project", entityId: projectID, relation: role.rawValue, subject: "group", subjectId: groupID)
    }

    func removeGroupFromProject(groupID: String, projectID: String, role: GroupProjectRole) async throws {
        try await deleteRelationship(
            entity: "project", entityId: projectID, relation: role.rawValue, subject: "group", subjectId: groupID)
    }

    func checkGroupBasedPermission(userID: String, permission: String, resource: String, resourceId: String)
        async throws -> Bool
    {
        return checkPermissionResult && !deniedResources.contains(resource)
            && !deniedPermissions.contains(permission)
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

    /// Storage key for the testing SpiceDB mock's per-permission denials.
    private struct SpiceDBMockDeniedPermissionsKey: StorageKey {
        typealias Value = Set<String>
    }

    /// In testing mode, permission names the mock SpiceDB denies even while
    /// `spicedbMockAllows` is true. Complements `spicedbMockDeniedResources`
    /// for handlers that check several verbs on the *same* resource type —
    /// e.g. snapshot export, which needs `export` and must not settle for
    /// `read`. Empty by default.
    var spicedbMockDeniedPermissions: Set<String> {
        get { storage[SpiceDBMockDeniedPermissionsKey.self] ?? [] }
        set { storage[SpiceDBMockDeniedPermissionsKey.self] = newValue }
    }

    /// Storage key for making the testing SpiceDB mock's writes fail.
    private struct SpiceDBMockWritesFailKey: StorageKey {
        typealias Value = Bool
    }

    /// In testing mode, makes the mock SpiceDB throw on relationship writes so
    /// tests can exercise partial-failure handling. Off by default.
    var spicedbMockWritesFail: Bool {
        get { storage[SpiceDBMockWritesFailKey.self] ?? false }
        set { storage[SpiceDBMockWritesFailKey.self] = newValue }
    }

    /// Storage key for the testing SpiceDB mock's canned relationships.
    private struct SpiceDBMockRelationshipsKey: StorageKey {
        typealias Value = [RelationshipTuple]
    }

    /// In testing mode, the relationships the mock SpiceDB's
    /// `readRelationships` serves, so tests can exercise export-driven flows
    /// (the IAM bindings backfill). Empty by default.
    var spicedbMockRelationships: [RelationshipTuple] {
        get { storage[SpiceDBMockRelationshipsKey.self] ?? [] }
        set { storage[SpiceDBMockRelationshipsKey.self] = newValue }
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
                    deniedPermissions: spicedbMockDeniedPermissions,
                    recorder: spicedbMockRecorder,
                    writesFail: spicedbMockWritesFail,
                    relationships: spicedbMockRelationships
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
    /// The SpiceDB service, wrapped so every permission check is also
    /// shadow-evaluated through Cedar (IAM phase 4, issue #481). Request-level
    /// on purpose: every middleware and handler check site reaches SpiceDB
    /// through this accessor, so shadow coverage is total by construction —
    /// including check sites added after this shipped.
    var spicedb: SpiceDBServiceProtocol {
        get throws {
            let inner = try self.application.spicedb
            guard self.application.iamShadowConfig.enabled else { return inner }
            return ShadowingSpiceDBService(
                inner: inner,
                shadow: self.application.iamShadow,
                path: self.url.path,
                method: self.method.rawValue,
                requestID: self.id
            )
        }
    }
}
