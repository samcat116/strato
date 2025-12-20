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
    /// Uses retry logic to handle race conditions where two requests try to create the same mapping concurrently.
    static func upsert(
        organizationID: UUID,
        resourceType: ResourceType,
        externalId: String,
        internalId: UUID,
        on db: Database
    ) async throws {
        // Try to find and update existing, or create new with retry for race conditions
        for attempt in 1...3 {
            // Check if mapping already exists
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

            // Try to create new mapping
            let mapping = SCIMExternalID(
                organizationID: organizationID,
                resourceType: resourceType.rawValue,
                externalId: externalId,
                internalId: internalId
            )
            do {
                try await mapping.save(on: db)
                return
            } catch {
                // If unique constraint violation, retry to find the existing record
                let errorDescription = String(describing: error).lowercased()
                if errorDescription.contains("unique") || errorDescription.contains("duplicate") {
                    if attempt < 3 {
                        continue
                    }
                }
                throw error
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
