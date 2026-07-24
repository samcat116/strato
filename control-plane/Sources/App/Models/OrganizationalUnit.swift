import Fluent
import Vapor
import Foundation

final class OrganizationalUnit: Model, @unchecked Sendable {
    static let schema = "organizational_units"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "description")
    var description: String

    // Hierarchical relationships
    @Parent(key: "organization_id")
    var organization: Organization

    @OptionalParent(key: "parent_ou_id")
    var parentOU: OrganizationalUnit?

    // Path for efficient hierarchy queries (e.g., "/org-uuid/ou-uuid/ou-uuid")
    @Field(key: "path")
    var path: String

    // Depth in hierarchy (0 for direct children of org, 1 for their children, etc.)
    @Field(key: "depth")
    var depth: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    // Relationships
    @Children(for: \.$parentOU)
    var childOUs: [OrganizationalUnit]

    @Children(for: \.$organizationalUnit)
    var projects: [Project]

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        description: String,
        organizationID: UUID,
        parentOUID: UUID? = nil,
        path: String,
        depth: Int
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.$organization.id = organizationID
        self.$parentOU.id = parentOUID
        self.path = path
        self.depth = depth
    }
}

extension OrganizationalUnit: Content {}

extension OrganizationalUnit {
    struct Public: Content {
        let id: UUID?
        let name: String
        let description: String
        let organizationId: UUID
        let parentOuId: UUID?
        let path: String
        let depth: Int
        let createdAt: Date?
    }

    func asPublic() -> Public {
        return Public(
            id: self.id,
            name: self.name,
            description: self.description,
            organizationId: self.$organization.id,
            parentOuId: self.$parentOU.id,
            path: self.path,
            depth: self.depth,
            createdAt: self.createdAt
        )
    }
}

// MARK: - Helper Methods

extension OrganizationalUnit {
    /// Builds the path string for this OU based on its hierarchy
    func buildPath(on db: Database) async throws -> String {
        var pathComponents: [String] = []

        // Add organization ID as root
        pathComponents.append(self.$organization.id.uuidString)

        // Walk up the parent chain
        var currentOU: OrganizationalUnit? = self
        var ouChain: [UUID] = []

        while let ou = currentOU, let parentId = ou.$parentOU.id {
            ouChain.insert(parentId, at: 0)
            currentOU = try await OrganizationalUnit.find(parentId, on: db)
        }

        // Add all parent OUs to path
        pathComponents.append(contentsOf: ouChain.map { $0.uuidString })

        // Add self if we have an ID
        if let selfId = self.id {
            pathComponents.append(selfId.uuidString)
        }

        return "/" + pathComponents.joined(separator: "/")
    }

    /// Calculates the depth of this OU in the hierarchy
    func calculateDepth(on db: Database) async throws -> Int {
        var depth = 0
        var currentOU: OrganizationalUnit? = self

        while let ou = currentOU, let parentId = ou.$parentOU.id {
            depth += 1
            currentOU = try await OrganizationalUnit.find(parentId, on: db)
        }

        return depth
    }

    /// Gets all descendant OUs (children, grandchildren, etc.).
    ///
    /// `path` is a true materialized path (`/orgId/ouId/…/selfId`), so a
    /// descendant is exactly a row whose path extends this one. Matching that
    /// prefix is indexable; the `LIKE '%<uuid>%'` contains-match it replaced
    /// could only ever be a sequential scan (issue #692).
    func descendants(on db: Database) async throws -> [OrganizationalUnit] {
        try await OrganizationalUnit.descendants(ofPath: path, on: db)
    }

    /// Descendants of the folder that had `path`. Split out for the move path,
    /// which must find the subtree by the path the folder carried *before* it
    /// moved — the descendants' own paths are only rewritten afterwards.
    ///
    /// Sorted by name so a caller assembling a tree from one flat load orders
    /// each sibling group the way the per-level queries it replaced did.
    static func descendants(ofPath path: String, on db: Database) async throws -> [OrganizationalUnit] {
        try await OrganizationalUnit.query(on: db)
            .filter(\.$path, .contains(inverse: false, .prefix), "\(path)/")
            .sort(\.$name)
            .all()
    }

    /// This folder's id plus every descendant's — the folder ids a
    /// folder-scoped quota or listing spans.
    func selfAndDescendantIDs(on db: Database) async throws -> [UUID] {
        guard let selfId = self.id else { return [] }
        let descendantIDs = try await descendants(on: db).compactMap { $0.id }
        return [selfId] + descendantIDs
    }

    /// The IDs of this OU and every ancestor OU up to (but excluding) the root
    /// organization, derived from the materialized `path`. The `path` is
    /// `/orgId/ouId/…/selfId`, so its first component is the organization and
    /// every remaining component is an OU from the root ancestor down to self.
    /// Falls back to just this OU's own id when the path can't be parsed.
    func ancestorAndSelfOUIDs() -> [UUID] {
        let ids = path.split(separator: "/").dropFirst().compactMap { UUID(uuidString: String($0)) }
        if ids.isEmpty, let selfId = self.id {
            return [selfId]
        }
        return ids
    }
}

// MARK: - DTOs

struct CreateOrganizationalUnitRequest: Content {
    let name: String
    let description: String
    var parentOuId: UUID?
}

struct UpdateOrganizationalUnitRequest: Content {
    let name: String?
    let description: String?
}

struct OrganizationalUnitResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let organizationId: UUID
    let parentOuId: UUID?
    let path: String
    let depth: Int
    let createdAt: Date?
    let childOuCount: Int?
    let projectCount: Int?

    init(from ou: OrganizationalUnit, childOuCount: Int? = nil, projectCount: Int? = nil) {
        self.id = ou.id
        self.name = ou.name
        self.description = ou.description
        self.organizationId = ou.$organization.id
        self.parentOuId = ou.$parentOU.id
        self.path = ou.path
        self.depth = ou.depth
        self.createdAt = ou.createdAt
        self.childOuCount = childOuCount
        self.projectCount = projectCount
    }
}
