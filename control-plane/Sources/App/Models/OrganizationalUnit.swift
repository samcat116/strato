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
    
    /// Gets all descendant OUs (children, grandchildren, etc.)
    func descendants(on db: Database) async throws -> [OrganizationalUnit] {
        guard let selfId = self.id else { return [] }
        
        return try await OrganizationalUnit.query(on: db)
            .filter(\.$path ~~ selfId.uuidString)
            .filter(\.$id != selfId)
            .all()
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