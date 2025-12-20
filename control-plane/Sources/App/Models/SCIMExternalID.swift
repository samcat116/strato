import Fluent
import Vapor
import Foundation

final class SCIMExternalID: Model, @unchecked Sendable {
    static let schema = "scim_external_ids"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "organization_id")
    var organization: Organization

    @Field(key: "resource_type")
    var resourceType: String // "User" or "Group"

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
    static func upsert(
        organizationID: UUID,
        resourceType: ResourceType,
        externalId: String,
        internalId: UUID,
        on db: Database
    ) async throws {
        // Check if mapping already exists
        if let existing = try await SCIMExternalID.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$resourceType == resourceType.rawValue)
            .filter(\.$externalId == externalId)
            .first()
        {
            existing.internalId = internalId
            try await existing.save(on: db)
        } else {
            let mapping = SCIMExternalID(
                organizationID: organizationID,
                resourceType: resourceType.rawValue,
                externalId: externalId,
                internalId: internalId
            )
            try await mapping.save(on: db)
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
