import Foundation
import Vapor
import Fluent

struct OrganizationalUnitController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let organizations = routes.grouped("organizations")

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
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Verify user has access to organization
        try await verifyOrganizationAccess(user: user, organizationID: organizationID, on: req.db)

        // Get all OUs in the organization (top-level only)
        let ous = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$organization.$id, .equal, organizationID)
            .filter(\.$parentOU.$id == nil) // Only top-level OUs
            .sort(\.$name)
            .all()

        var responses: [OrganizationalUnitResponse] = []

        for ou in ous {
            // Get counts for response
            let childOuCount = try await OrganizationalUnit.query(on: req.db)
                .filter(\.$parentOU.$id, .equal, ou.id)
                .count()

            let projectCount = try await Project.query(on: req.db)
                .filter(\.$organizationalUnit.$id, .equal, ou.id)
                .count()

            let response = OrganizationalUnitResponse(
                from: ou,
                childOuCount: Int(childOuCount),
                projectCount: Int(projectCount)
            )
            responses.append(response)
        }

        return responses
    }

    func show(req: Request) async throws -> OrganizationalUnitResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let ouID = req.parameters.get("ouID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or OU ID")
        }

        // Verify user has access to organization
        try await verifyOrganizationAccess(user: user, organizationID: organizationID, on: req.db)

        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Organizational unit not found")
        }

        // Verify OU belongs to the organization
        if ou.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "OU does not belong to the specified organization")
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
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        let createRequest = try req.content.decode(CreateOrganizationalUnitRequest.self)

        // Verify user has admin access to organization
        try await verifyOrganizationAdminAccess(user: user, organizationID: organizationID, on: req.db)

        // Validate parent OU if specified
        var parentOU: OrganizationalUnit?
        if let parentOUID = createRequest.parentOuId {
            guard let parent = try await OrganizationalUnit.find(parentOUID, on: req.db) else {
                throw Abort(.badRequest, reason: "Parent OU not found")
            }

            // Verify parent belongs to same organization
            if parent.$organization.id != organizationID {
                throw Abort(.badRequest, reason: "Parent OU must belong to the same organization")
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
            throw Abort(.conflict, reason: "OU name already exists in this scope")
        }

        // Calculate depth and path
        let depth = try await calculateDepth(parentOU: parentOU, on: req.db)

        // Create OU
        let ou = OrganizationalUnit(
            name: createRequest.name,
            description: createRequest.description,
            organizationID: organizationID,
            parentOUID: createRequest.parentOuId,
            path: "", // Will be updated after save
            depth: depth
        )

        try await ou.save(on: req.db)

        // Update path with actual ID
        ou.path = try await ou.buildPath(on: req.db)
        try await ou.save(on: req.db)

        return OrganizationalUnitResponse(from: ou, childOuCount: 0, projectCount: 0)
    }

    func update(req: Request) async throws -> OrganizationalUnitResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let ouID = req.parameters.get("ouID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or OU ID")
        }

        let updateRequest = try req.content.decode(UpdateOrganizationalUnitRequest.self)

        // Verify user has admin access
        try await verifyOrganizationAdminAccess(user: user, organizationID: organizationID, on: req.db)

        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Organizational unit not found")
        }

        // Verify OU belongs to organization
        if ou.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "OU does not belong to the specified organization")
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
                throw Abort(.conflict, reason: "OU name already exists in this scope")
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
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let ouID = req.parameters.get("ouID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or OU ID")
        }

        // Verify user has admin access
        try await verifyOrganizationAdminAccess(user: user, organizationID: organizationID, on: req.db)

        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Organizational unit not found")
        }

        // Verify OU belongs to organization
        if ou.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "OU does not belong to the specified organization")
        }

        // Check for dependent resources
        let childOUCount = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$parentOU.$id, .equal, ouID)
            .count()

        if childOUCount > 0 {
            throw Abort(.conflict, reason: "Cannot delete OU with child OUs. Move or delete child OUs first.")
        }

        let projectCount = try await Project.query(on: req.db)
            .filter(\.$organizationalUnit.$id, .equal, ouID)
            .count()

        if projectCount > 0 {
            throw Abort(.conflict, reason: "Cannot delete OU with projects. Move or delete projects first.")
        }

        try await ou.delete(on: req.db)
        return .noContent
    }

    // MARK: - Hierarchy Operations

    func getTree(req: Request) async throws -> OrganizationalUnitTreeResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let ouID = req.parameters.get("ouID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or OU ID")
        }

        // Verify user has access
        try await verifyOrganizationAccess(user: user, organizationID: organizationID, on: req.db)

        guard let rootOU = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Organizational unit not found")
        }

        return try await buildOUTree(ou: rootOU, on: req.db)
    }

    func move(req: Request) async throws -> OrganizationalUnitResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let ouID = req.parameters.get("ouID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or OU ID")
        }

        let moveRequest = try req.content.decode(MoveOrganizationalUnitRequest.self)

        // Verify user has admin access
        try await verifyOrganizationAdminAccess(user: user, organizationID: organizationID, on: req.db)

        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Organizational unit not found")
        }

        // Validate new parent
        var newParent: OrganizationalUnit?
        if let newParentID = moveRequest.newParentOuId {
            guard let parent = try await OrganizationalUnit.find(newParentID, on: req.db) else {
                throw Abort(.badRequest, reason: "New parent OU not found")
            }

            // Prevent moving to a descendant (circular reference)
            let descendants = try await ou.descendants(on: req.db)
            if descendants.contains(where: { $0.id == newParentID }) {
                throw Abort(.badRequest, reason: "Cannot move OU to its own descendant")
            }

            newParent = parent
        }

        // Update OU
        ou.$parentOU.id = moveRequest.newParentOuId
        ou.depth = try await calculateDepth(parentOU: newParent, on: req.db)
        ou.path = try await ou.buildPath(on: req.db)

        try await ou.save(on: req.db)

        // Update paths for all descendants
        try await updateDescendantPaths(ou: ou, on: req.db)

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
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let ouID = req.parameters.get("ouID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or OU ID")
        }

        // Verify user has access
        try await verifyOrganizationAccess(user: user, organizationID: organizationID, on: req.db)

        // Get sub-OUs
        let subOUs = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$parentOU.$id, .equal, ouID)
            .sort(\.$name)
            .all()

        var responses: [OrganizationalUnitResponse] = []

        for subOU in subOUs {
            let childOuCount = try await OrganizationalUnit.query(on: req.db)
                .filter(\.$parentOU.$id, .equal, subOU.id)
                .count()

            let projectCount = try await Project.query(on: req.db)
                .filter(\.$organizationalUnit.$id, .equal, subOU.id)
                .count()

            let response = OrganizationalUnitResponse(
                from: subOU,
                childOuCount: Int(childOuCount),
                projectCount: Int(projectCount)
            )
            responses.append(response)
        }

        return responses
    }

    func createSubOU(req: Request) async throws -> OrganizationalUnitResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let parentOUID = req.parameters.get("ouID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or OU ID")
        }

        let createRequest = try req.content.decode(CreateOrganizationalUnitRequest.self)

        // Verify user has admin access to organization
        try await verifyOrganizationAdminAccess(user: user, organizationID: organizationID, on: req.db)

        // Validate parent OU exists and belongs to organization
        guard let parentOU = try await OrganizationalUnit.find(parentOUID, on: req.db) else {
            throw Abort(.badRequest, reason: "Parent OU not found")
        }

        // Verify parent belongs to same organization
        if parentOU.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Parent OU must belong to the same organization")
        }

        // Check for name uniqueness within parent scope
        let existingOU = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$organization.$id, .equal, organizationID)
            .filter(\.$name, .equal, createRequest.name)
            .filter(\.$parentOU.$id, .equal, parentOUID)
            .first()

        if existingOU != nil {
            throw Abort(.conflict, reason: "OU name already exists in this scope")
        }

        // Calculate depth
        let depth = parentOU.depth + 1

        // Create OU
        let ou = OrganizationalUnit(
            name: createRequest.name,
            description: createRequest.description,
            organizationID: organizationID,
            parentOUID: parentOUID,
            path: "", // Will be updated after save
            depth: depth
        )

        try await ou.save(on: req.db)

        // Update path with actual ID
        ou.path = try await ou.buildPath(on: req.db)
        try await ou.save(on: req.db)

        return OrganizationalUnitResponse(from: ou, childOuCount: 0, projectCount: 0)
    }

    // MARK: - Helper Methods

    private func verifyOrganizationAccess(user: User, organizationID: UUID, on db: Database) async throws {
        let userOrg = try await UserOrganization.query(on: db)
            .filter(\.$user.$id, .equal, user.id!)
            .filter(\.$organization.$id, .equal, organizationID)
            .first()

        guard userOrg != nil else {
            throw Abort(.forbidden, reason: "Not a member of this organization")
        }
    }

    private func verifyOrganizationAdminAccess(user: User, organizationID: UUID, on db: Database) async throws {
        let userOrg = try await UserOrganization.query(on: db)
            .filter(\.$user.$id, .equal, user.id!)
            .filter(\.$organization.$id, .equal, organizationID)
            .first()

        guard let userOrganization = userOrg, userOrganization.role == "admin" else {
            throw Abort(.forbidden, reason: "Admin access required")
        }
    }

    private func calculateDepth(parentOU: OrganizationalUnit?, on db: Database) async throws -> Int {
        if let parent = parentOU {
            return parent.depth + 1
        }
        return 0
    }

    private func buildOUTree(ou: OrganizationalUnit, on db: Database) async throws -> OrganizationalUnitTreeResponse {
        let childOUs = try await OrganizationalUnit.query(on: db)
            .filter(\.$parentOU.$id, .equal, ou.id)
            .sort(\.$name)
            .all()

        var children: [OrganizationalUnitTreeResponse] = []
        for childOU in childOUs {
            let childTree = try await buildOUTree(ou: childOU, on: db)
            children.append(childTree)
        }

        let projectCount = try await Project.query(on: db)
            .filter(\.$organizationalUnit.$id, .equal, ou.id)
            .count()

        return OrganizationalUnitTreeResponse(
            id: ou.id,
            name: ou.name,
            description: ou.description,
            path: ou.path,
            depth: ou.depth,
            projectCount: Int(projectCount),
            children: children
        )
    }

    private func updateDescendantPaths(ou: OrganizationalUnit, on db: Database) async throws {
        guard let ouId = ou.id else { return }

        let descendants = try await OrganizationalUnit.query(on: db)
            .filter(\.$path ~~ ouId.uuidString)
            .filter(\.$id != ouId)
            .all()

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
