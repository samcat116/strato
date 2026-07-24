import Foundation
import Vapor
import Fluent

struct OrganizationalUnitController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let organizations = routes.grouped("api", "organizations")

        // OU routes under organization context
        organizations.group(":organizationID") { org in
            let ous = org.grouped("ous")
            ous.get(use: index)
            ous.post(use: create)

            ous.group(":ouID") { ou in
                ou.get(use: show)
                ou.put(use: update)
                ou.delete(use: delete)
                ou.get("tree", use: getTree)
                ou.post("move", use: move)

                // Sub-OU operations
                let subOUs = ou.grouped("ous")
                subOUs.get(use: indexSubOUs)
                subOUs.post(use: createSubOU)
            }
        }
    }

    // MARK: - OU CRUD Operations

    func index(req: Request) async throws -> [OrganizationalUnitResponse] {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        // Get all OUs in the organization (top-level only)
        let ous = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$organization.$id, .equal, organizationID)
            .filter(\.$parentOU.$id == nil)  // Only top-level OUs
            .sort(\.$name)
            .all()

        return try await Self.responses(for: ous, on: req.db)
    }

    func show(req: Request) async throws -> OrganizationalUnitResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or folder ID")
        }

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Folder not found")
        }

        // Verify OU belongs to the organization
        if ou.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }

        // Get counts
        let childOuCount = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$parentOU.$id, .equal, ouID)
            .count()

        let projectCount = try await Project.query(on: req.db)
            .filter(\.$organizationalUnit.$id, .equal, ouID)
            .count()

        return OrganizationalUnitResponse(
            from: ou,
            childOuCount: Int(childOuCount),
            projectCount: Int(projectCount)
        )
    }

    func create(req: Request) async throws -> OrganizationalUnitResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        let createRequest = try req.content.decode(CreateOrganizationalUnitRequest.self)

        // Verify user has admin access to organization
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        // Validate parent OU if specified
        var parentOU: OrganizationalUnit?
        if let parentOUID = createRequest.parentOuId {
            guard let parent = try await OrganizationalUnit.find(parentOUID, on: req.db) else {
                throw Abort(.badRequest, reason: "Parent folder not found")
            }

            // Verify parent belongs to same organization
            if parent.$organization.id != organizationID {
                throw Abort(.badRequest, reason: "Parent folder must belong to the same organization")
            }

            parentOU = parent
        }

        // Check for name uniqueness within parent scope
        let query = OrganizationalUnit.query(on: req.db)
            .filter(\.$organization.$id, .equal, organizationID)
            .filter(\.$name, .equal, createRequest.name)

        if let parentOUID = createRequest.parentOuId {
            query.filter(\.$parentOU.$id, .equal, parentOUID)
        } else {
            query.filter(\.$parentOU.$id == nil)
        }

        let existingOU = try await query.first()
        if existingOU != nil {
            throw Abort(.conflict, reason: "Folder name already exists in this scope")
        }

        // Calculate depth and path
        let depth = try await calculateDepth(parentOU: parentOU, on: req.db)

        // Create OU
        let ou = OrganizationalUnit(
            name: createRequest.name,
            description: createRequest.description,
            organizationID: organizationID,
            parentOUID: createRequest.parentOuId,
            path: "",  // Will be updated after save
            depth: depth
        )

        try await ou.save(on: req.db)

        // Update path with actual ID
        ou.path = try await ou.buildPath(on: req.db)
        try await ou.save(on: req.db)

        return OrganizationalUnitResponse(from: ou, childOuCount: 0, projectCount: 0)
    }

    func update(req: Request) async throws -> OrganizationalUnitResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or folder ID")
        }

        let updateRequest = try req.content.decode(UpdateOrganizationalUnitRequest.self)

        // Verify user has admin access
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Folder not found")
        }

        // Verify OU belongs to organization
        if ou.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }

        // Update fields
        if let name = updateRequest.name {
            // Check name uniqueness in same scope
            let query = OrganizationalUnit.query(on: req.db)
                .filter(\.$organization.$id, .equal, organizationID)
                .filter(\.$name, .equal, name)
                .filter(\.$id, .notEqual, ouID)

            if let parentOUID = ou.$parentOU.id {
                query.filter(\.$parentOU.$id, .equal, parentOUID)
            } else {
                query.filter(\.$parentOU.$id == nil)
            }

            let existingOU = try await query.first()
            if existingOU != nil {
                throw Abort(.conflict, reason: "Folder name already exists in this scope")
            }

            ou.name = name
        }

        if let description = updateRequest.description {
            ou.description = description
        }

        try await ou.save(on: req.db)

        // Get counts for response
        let childOuCount = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$parentOU.$id, .equal, ouID)
            .count()

        let projectCount = try await Project.query(on: req.db)
            .filter(\.$organizationalUnit.$id, .equal, ouID)
            .count()

        return OrganizationalUnitResponse(
            from: ou,
            childOuCount: Int(childOuCount),
            projectCount: Int(projectCount)
        )
    }

    func delete(req: Request) async throws -> HTTPStatus {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or folder ID")
        }

        // Verify user has admin access
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Folder not found")
        }

        // Verify OU belongs to organization
        if ou.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }

        // Check for dependent resources
        let childOUCount = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$parentOU.$id, .equal, ouID)
            .count()

        if childOUCount > 0 {
            throw Abort(
                .conflict, reason: "Cannot delete folder with child folders. Move or delete child folders first.")
        }

        let projectCount = try await Project.query(on: req.db)
            .filter(\.$organizationalUnit.$id, .equal, ouID)
            .count()

        if projectCount > 0 {
            throw Abort(.conflict, reason: "Cannot delete folder with projects. Move or delete projects first.")
        }

        try await ou.delete(on: req.db)
        return .noContent
    }

    // MARK: - Hierarchy Operations

    func getTree(req: Request) async throws -> OrganizationalUnitTreeResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or folder ID")
        }

        // Verify user has access
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        guard let rootOU = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Folder not found")
        }

        // Verify OU belongs to the organization
        if rootOU.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }

        return try await buildOUTree(ou: rootOU, on: req.db)
    }

    func move(req: Request) async throws -> OrganizationalUnitResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or folder ID")
        }

        let moveRequest = try req.content.decode(MoveOrganizationalUnitRequest.self)

        // Verify user has admin access
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Folder not found")
        }

        // Verify OU belongs to the organization
        if ou.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }

        // Validate new parent
        var newParent: OrganizationalUnit?
        if let newParentID = moveRequest.newParentOuId {
            guard let parent = try await OrganizationalUnit.find(newParentID, on: req.db) else {
                throw Abort(.badRequest, reason: "New parent folder not found")
            }

            // Verify new parent belongs to same organization
            if parent.$organization.id != organizationID {
                throw Abort(.badRequest, reason: "New parent folder must belong to the same organization")
            }

            // Prevent moving to a descendant (circular reference)
            let descendants = try await ou.descendants(on: req.db)
            if descendants.contains(where: { $0.id == newParentID }) {
                throw Abort(.badRequest, reason: "Cannot move folder to its own descendant")
            }

            newParent = parent
        }

        // Update OU
        let previousPath = ou.path
        ou.$parentOU.id = moveRequest.newParentOuId
        ou.depth = try await calculateDepth(parentOU: newParent, on: req.db)
        ou.path = try await ou.buildPath(on: req.db)

        try await ou.save(on: req.db)

        // Update paths for all descendants
        try await updateDescendantPaths(previousPath: previousPath, on: req.db)

        // Get counts for response
        let childOuCount = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$parentOU.$id, .equal, ouID)
            .count()

        let projectCount = try await Project.query(on: req.db)
            .filter(\.$organizationalUnit.$id, .equal, ouID)
            .count()

        return OrganizationalUnitResponse(
            from: ou,
            childOuCount: Int(childOuCount),
            projectCount: Int(projectCount)
        )
    }

    func indexSubOUs(req: Request) async throws -> [OrganizationalUnitResponse] {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or folder ID")
        }

        // Verify user has access
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        guard let parentOU = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Folder not found")
        }

        // Verify OU belongs to the organization
        if parentOU.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }

        // Get sub-OUs
        let subOUs = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$parentOU.$id, .equal, ouID)
            .sort(\.$name)
            .all()

        return try await Self.responses(for: subOUs, on: req.db)
    }

    func createSubOU(req: Request) async throws -> OrganizationalUnitResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let parentOUID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or folder ID")
        }

        let createRequest = try req.content.decode(CreateOrganizationalUnitRequest.self)

        // Verify user has admin access to organization
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        // Validate parent OU exists and belongs to organization
        guard let parentOU = try await OrganizationalUnit.find(parentOUID, on: req.db) else {
            throw Abort(.badRequest, reason: "Parent folder not found")
        }

        // Verify parent belongs to same organization
        if parentOU.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Parent folder must belong to the same organization")
        }

        // Check for name uniqueness within parent scope
        let existingOU = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$organization.$id, .equal, organizationID)
            .filter(\.$name, .equal, createRequest.name)
            .filter(\.$parentOU.$id, .equal, parentOUID)
            .first()

        if existingOU != nil {
            throw Abort(.conflict, reason: "Folder name already exists in this scope")
        }

        // Calculate depth
        let depth = parentOU.depth + 1

        // Create OU
        let ou = OrganizationalUnit(
            name: createRequest.name,
            description: createRequest.description,
            organizationID: organizationID,
            parentOUID: parentOUID,
            path: "",  // Will be updated after save
            depth: depth
        )

        try await ou.save(on: req.db)

        // Update path with actual ID
        ou.path = try await ou.buildPath(on: req.db)
        try await ou.save(on: req.db)

        return OrganizationalUnitResponse(from: ou, childOuCount: 0, projectCount: 0)
    }

    // MARK: - Helper Methods

    private func calculateDepth(parentOU: OrganizationalUnit?, on db: Database) async throws -> Int {
        if let parent = parentOU {
            return parent.depth + 1
        }
        return 0
    }

    /// The folder rows a list endpoint returns, each carrying its child and
    /// project counts — both measured for the whole page in one grouped
    /// aggregate rather than two queries per row.
    private static func responses(
        for ous: [OrganizationalUnit],
        on db: Database
    ) async throws -> [OrganizationalUnitResponse] {
        let ouIDs = ous.compactMap { $0.id }
        let childCounts = try await OrganizationalUnit.counts(groupedBy: \.$parentOU, in: ouIDs, on: db)
        let projectCounts = try await Project.counts(groupedBy: \.$organizationalUnit, in: ouIDs, on: db)

        return ous.map { ou in
            OrganizationalUnitResponse(
                from: ou,
                childOuCount: ou.id.flatMap { childCounts[$0] } ?? 0,
                projectCount: ou.id.flatMap { projectCounts[$0] } ?? 0
            )
        }
    }

    /// The subtree rooted at `ou`, from one load of its descendants and one
    /// grouped project count over them.
    ///
    /// The recursion this replaced cost two queries per folder, so a deep tree
    /// paid for its own shape on every request. Descendants come from the
    /// materialized `path` the folder already carries.
    private func buildOUTree(ou: OrganizationalUnit, on db: Database) async throws
        -> OrganizationalUnitTreeResponse
    {
        let descendants = try await ou.descendants(on: db)
        let subtree = [ou] + descendants
        let projectCounts = try await Project.counts(
            groupedBy: \.$organizationalUnit, in: subtree.compactMap { $0.id }, on: db)

        var childrenByParent: [UUID: [OrganizationalUnit]] = [:]
        for descendant in descendants {
            guard let parentID = descendant.$parentOU.id else { continue }
            childrenByParent[parentID, default: []].append(descendant)
        }

        func tree(_ node: OrganizationalUnit) -> OrganizationalUnitTreeResponse {
            let children = node.id.map { childrenByParent[$0] ?? [] } ?? []
            return OrganizationalUnitTreeResponse(
                id: node.id,
                name: node.name,
                description: node.description,
                path: node.path,
                depth: node.depth,
                projectCount: node.id.flatMap { projectCounts[$0] } ?? 0,
                children: children.map(tree)
            )
        }
        return tree(ou)
    }

    /// Rewrites the materialized `path` (and `depth`) of everything beneath a
    /// folder that has just moved.
    ///
    /// Matched on the path the folder carried *before* the move: the moved row
    /// is already saved with its new path, but its descendants still extend the
    /// old one — that is exactly what this rewrites.
    private func updateDescendantPaths(previousPath: String, on db: Database) async throws {
        let descendants = try await OrganizationalUnit.descendants(ofPath: previousPath, on: db)

        for descendant in descendants {
            descendant.path = try await descendant.buildPath(on: db)
            descendant.depth = try await descendant.calculateDepth(on: db)
            try await descendant.save(on: db)
        }
    }
}

// MARK: - Additional DTOs

struct MoveOrganizationalUnitRequest: Content {
    let newParentOuId: UUID?
}

struct OrganizationalUnitTreeResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let path: String
    let depth: Int
    let projectCount: Int
    let children: [OrganizationalUnitTreeResponse]
}
