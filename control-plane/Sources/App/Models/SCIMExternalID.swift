import Fluent
import Vapor
import Foundation

/// Safety: this mutable Fluent model stays inside one logical operation; child tasks
/// receive IDs or immutable snapshots and reload their own instance.
final class SCIMExternalID: Model, @unchecked Sendable {
    static let schema = "scim_external_ids"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "organization_id")
    var organization: Organization

    @Field(key: "resource_type")
    var resourceType: String  // "User" or "Group"

    @Field(key: "external_id")
    var externalId: String

    @Field(key: "internal_id")
    var internalId: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        organizationID: UUID,
        resourceType: String,
        externalId: String,
        internalId: UUID
    ) {
        self.id = id
        self.$organization.id = organizationID
        self.resourceType = resourceType
        self.externalId = externalId
        self.internalId = internalId
    }
}

extension SCIMExternalID: Content {}

// MARK: - Resource Type

extension SCIMExternalID {
    enum ResourceType: String, Codable, Sendable {
        case user = "User"
        case group = "Group"
    }
}

// MARK: - Helper Methods

extension SCIMExternalID {
    /// Find internal ID by external ID for a specific resource type in an organization
    static func findInternalID(
        externalId: String,
        resourceType: ResourceType,
        organizationID: UUID,
        on db: Database
    ) async throws -> UUID? {
        let mapping = try await SCIMExternalID.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$resourceType == resourceType.rawValue)
            .filter(\.$externalId == externalId)
            .first()

        return mapping?.internalId
    }

    /// Find external ID by internal ID for a specific resource type in an organization
    static func findExternalID(
        internalId: UUID,
        resourceType: ResourceType,
        organizationID: UUID,
        on db: Database
    ) async throws -> String? {
        let mapping = try await SCIMExternalID.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$resourceType == resourceType.rawValue)
            .filter(\.$internalId == internalId)
            .first()

        return mapping?.externalId
    }

    /// Create or update an external ID mapping
    /// Uses retry logic to handle race conditions where two requests try to create the same mapping concurrently.
    static func upsert(
        organizationID: UUID,
        resourceType: ResourceType,
        externalId: String,
        internalId: UUID,
        on db: Database
    ) async throws {
        // Only an autocommit INSERT race can be recovered here. A failed
        // INSERT inside an outer transaction aborts it; its owner must decide
        // whether the complete transaction is safe to replay.
        for attempt in 1...3 {
            if let existing = try await SCIMExternalID.query(on: db)
                .filter(\.$organization.$id == organizationID)
                .filter(\.$resourceType == resourceType.rawValue)
                .filter(\.$externalId == externalId)
                .first()
            {
                existing.internalId = internalId
                try await existing.save(on: db)
                return
            }

            let mapping = SCIMExternalID(
                organizationID: organizationID, resourceType: resourceType.rawValue,
                externalId: externalId, internalId: internalId
            )
            do {
                try await mapping.save(on: db)
                return
            } catch {
                guard !db.inTransaction, attempt < 3,
                    DatabaseTransactionFailure.uniqueConstraint(error)
                        == "uq:scim_external_ids.organization_id+scim_external_ids.resource"
                else { throw error }
                // Reread the winner on the next attempt. Lookup/update errors
                // are outside this catch and propagate without replay.
            }
        }
    }

    /// Delete mapping for a specific internal resource
    static func deleteMapping(
        internalId: UUID,
        resourceType: ResourceType,
        organizationID: UUID,
        on db: Database
    ) async throws {
        try await SCIMExternalID.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$resourceType == resourceType.rawValue)
            .filter(\.$internalId == internalId)
            .delete()
    }
}
