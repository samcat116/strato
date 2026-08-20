import ControlPlanePostgres
import Fluent
import Foundation
import Vapor

struct OrganizationalUnit: Content, Equatable, Sendable {
    static let schema = "organizational_units"

    let id: UUID?
    let name: String
    let description: String
    let organizationID: UUID
    let parentOUID: UUID?
    let path: String
    let depth: Int
    let createdAt: Date?
    let updatedAt: Date?

    init(
        id: UUID? = UUID(),
        name: String,
        description: String,
        organizationID: UUID,
        parentOUID: UUID? = nil,
        path: String,
        depth: Int,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.organizationID = organizationID
        self.parentOUID = parentOUID
        self.path = path
        self.depth = depth
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(snapshot: OrganizationalUnitSnapshot) {
        self.init(
            id: snapshot.id,
            name: snapshot.name,
            description: snapshot.description,
            organizationID: snapshot.organizationID,
            parentOUID: snapshot.parentID,
            path: snapshot.path,
            depth: snapshot.depth,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt)
    }

    func requireID() throws -> UUID {
        guard let id else { throw Abort(.internalServerError, reason: "Folder has no identifier") }
        return id
    }

    func save(on db: any Database) async throws {
        _ = try await LegacyOrganizationalUnitStore.upsert(self, on: db)
    }

    static func find(_ id: UUID?, on db: any Database) async throws -> Self? {
        try await LegacyOrganizationalUnitStore.organizationalUnit(id: id, on: db)
    }

    static func all(on db: any Database) async throws -> [Self] {
        try await LegacyOrganizationalUnitStore.organizationalUnits(on: db)
    }

    func replacingPath(_ path: String, depth: Int? = nil) -> Self {
        Self(
            id: id, name: name, description: description,
            organizationID: organizationID, parentOUID: parentOUID,
            path: path, depth: depth ?? self.depth,
            createdAt: createdAt, updatedAt: updatedAt)
    }

    func replacingParent(_ parentOUID: UUID?) -> Self {
        Self(
            id: id, name: name, description: description,
            organizationID: organizationID, parentOUID: parentOUID,
            path: path, depth: depth,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}

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
            organizationId: self.organizationID,
            parentOuId: self.parentOUID,
            path: self.path,
            depth: self.depth,
            createdAt: self.createdAt
        )
    }
}

// MARK: - Helper Methods

extension OrganizationalUnit {
    /// The root component every materialized path starts from. Folders and
    /// projects both hang off it, so both derive it here.
    static func organizationPath(_ organizationID: UUID) -> String {
        "/\(organizationID.uuidString)"
    }

    /// The materialized path a folder carries beneath a parent whose own path is
    /// `parentPath` — another folder's `path`, or ``organizationPath(_:)`` for a
    /// top-level folder.
    static func path(under parentPath: String, folderID: UUID) -> String {
        "\(parentPath)/\(folderID.uuidString)"
    }

    /// Builds the path string for this OU based on its hierarchy
    func buildPath(on db: Database) async throws -> String {
        var pathComponents: [String] = []

        // Add organization ID as root
        pathComponents.append(self.organizationID.uuidString)

        // Walk up the parent chain
        var currentOU: OrganizationalUnit? = self
        var ouChain: [UUID] = []

        while let ou = currentOU, let parentId = ou.parentOUID {
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

        while let ou = currentOU, let parentId = ou.parentOUID {
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
        try await LegacyOrganizationalUnitStore.descendants(ofPath: path, on: db)
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

struct CreateOrganizationalUnitRequest: Content, ValidatedRequestBody {
    var name: String
    let description: String
    var parentOuId: UUID?

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
    }
}

struct UpdateOrganizationalUnitRequest: Content, ValidatedRequestBody {
    var name: String?
    let description: String?

    mutating func validate() throws {
        name = try Validate.name(name)
        try Validate.text(description)
    }
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
        self.organizationId = ou.organizationID
        self.parentOuId = ou.parentOUID
        self.path = ou.path
        self.depth = ou.depth
        self.createdAt = ou.createdAt
        self.childOuCount = childOuCount
        self.projectCount = projectCount
    }
}
