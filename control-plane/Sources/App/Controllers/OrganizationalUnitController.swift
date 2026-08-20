import ControlPlanePostgres
import Foundation
import Vapor

struct OrganizationalUnitController: RouteCollection {
    let hierarchy: HierarchyPersistence

    func boot(routes: RoutesBuilder) throws {
        let organizations = routes.grouped("api", "organizations")

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

                let subOUs = ou.grouped("ous")
                subOUs.get(use: indexSubOUs)
                subOUs.post(use: createSubOU)
            }
        }
    }

    func index(req: Request) async throws -> [OrganizationalUnitResponse] {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)
        let folders = try await hierarchy.organizationalUnits(
            organizationID: organizationID,
            parentID: nil
        )
        return try await Self.readable(folders, on: req).map(OrganizationalUnitResponse.init)
    }

    func show(req: Request) async throws -> OrganizationalUnitResponse {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let (organizationID, ouID) = try Self.identifiers(from: req)

        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)
        guard let folder = try await hierarchy.organizationalUnit(id: ouID) else {
            throw Abort(.notFound, reason: "Folder not found")
        }
        guard folder.organizationalUnit.organizationID == organizationID else {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }
        return OrganizationalUnitResponse(from: folder)
    }

    func create(req: Request) async throws -> OrganizationalUnitResponse {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }
        let input = try req.content.decodeValidated(CreateOrganizationalUnitRequest.self)

        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        return try await create(
            OrganizationalUnitWrite(
                organizationID: organizationID,
                parentID: input.parentOuId,
                name: input.name,
                description: input.description
            )
        )
    }

    func update(req: Request) async throws -> OrganizationalUnitResponse {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let (organizationID, ouID) = try Self.identifiers(from: req)
        let input = try req.content.decodeValidated(UpdateOrganizationalUnitRequest.self)

        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        switch try await hierarchy.updateOrganizationalUnit(
            id: ouID,
            organizationID: organizationID,
            name: input.name,
            description: input.description
        ) {
        case .updated(let folder):
            return OrganizationalUnitResponse(from: folder)
        case .notFound:
            throw Abort(.notFound, reason: "Folder not found")
        case .outsideOrganization:
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        case .duplicateName:
            throw Abort(.conflict, reason: "Folder name already exists in this scope")
        }
    }

    func delete(req: Request) async throws -> HTTPStatus {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let (organizationID, ouID) = try Self.identifiers(from: req)

        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        switch try await hierarchy.deleteOrganizationalUnit(id: ouID, organizationID: organizationID) {
        case .deleted:
            return .noContent
        case .notFound:
            throw Abort(.notFound, reason: "Folder not found")
        case .outsideOrganization:
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        case .hasChildren:
            throw Abort(
                .conflict,
                reason: "Cannot delete folder with child folders. Move or delete child folders first."
            )
        case .hasProjects:
            throw Abort(
                .conflict,
                reason: "Cannot delete folder with projects. Move or delete projects first."
            )
        }
    }

    func getTree(req: Request) async throws -> OrganizationalUnitTreeResponse {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let (organizationID, ouID) = try Self.identifiers(from: req)

        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)
        let subtree = try await hierarchy.organizationalUnitSubtree(rootID: ouID)
        guard let root = subtree.first(where: { $0.organizationalUnit.id == ouID }) else {
            throw Abort(.notFound, reason: "Folder not found")
        }
        guard root.organizationalUnit.organizationID == organizationID else {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }
        return Self.tree(rootID: ouID, from: subtree)
    }

    func move(req: Request) async throws -> OrganizationalUnitResponse {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let (organizationID, ouID) = try Self.identifiers(from: req)
        let input = try req.content.decode(MoveOrganizationalUnitRequest.self)

        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        switch try await hierarchy.moveOrganizationalUnit(
            id: ouID,
            organizationID: organizationID,
            newParentID: input.newParentOuId
        ) {
        case .moved(let folder):
            return OrganizationalUnitResponse(from: folder)
        case .notFound:
            throw Abort(.notFound, reason: "Folder not found")
        case .outsideOrganization:
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        case .parentNotFound:
            throw Abort(.badRequest, reason: "New parent folder not found")
        case .parentOutsideOrganization:
            throw Abort(.badRequest, reason: "New parent folder must belong to the same organization")
        case .circularReference:
            throw Abort(.badRequest, reason: "Cannot move folder to its own descendant")
        case .duplicateName:
            throw Abort(.conflict, reason: "Folder name already exists in this scope")
        }
    }

    func indexSubOUs(req: Request) async throws -> [OrganizationalUnitResponse] {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let (organizationID, ouID) = try Self.identifiers(from: req)

        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)
        guard let parent = try await hierarchy.organizationalUnit(id: ouID) else {
            throw Abort(.notFound, reason: "Folder not found")
        }
        guard parent.organizationalUnit.organizationID == organizationID else {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }

        let folders = try await hierarchy.organizationalUnits(
            organizationID: organizationID,
            parentID: ouID
        )
        return try await Self.readable(folders, on: req).map(OrganizationalUnitResponse.init)
    }

    func createSubOU(req: Request) async throws -> OrganizationalUnitResponse {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let (organizationID, parentID) = try Self.identifiers(from: req)
        let input = try req.content.decodeValidated(CreateOrganizationalUnitRequest.self)

        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        return try await create(
            OrganizationalUnitWrite(
                organizationID: organizationID,
                parentID: parentID,
                name: input.name,
                description: input.description
            )
        )
    }

    private func create(_ write: OrganizationalUnitWrite) async throws -> OrganizationalUnitResponse {
        switch try await hierarchy.createOrganizationalUnit(write) {
        case .created(let folder):
            return OrganizationalUnitResponse(from: folder)
        case .organizationNotFound:
            throw Abort(.badRequest, reason: "Organization not found")
        case .parentNotFound:
            throw Abort(.badRequest, reason: "Parent folder not found")
        case .parentOutsideOrganization:
            throw Abort(.badRequest, reason: "Parent folder must belong to the same organization")
        case .duplicateName:
            throw Abort(.conflict, reason: "Folder name already exists in this scope")
        }
    }

    /// Bare organization membership does not reveal its folder structure. The
    /// authorization engine evaluates all listed folders in one batch.
    private static func readable(
        _ folders: [OrganizationalUnitOverview],
        on req: Request
    ) async throws -> [OrganizationalUnitOverview] {
        guard !folders.isEmpty else { return [] }
        let nodes = folders.map {
            IAMNode(type: .organizationalUnit, id: $0.organizationalUnit.id)
        }
        let allowed = Set(try await req.canFilter("folder:read", on: nodes).map(\.id))
        return folders.filter { allowed.contains($0.organizationalUnit.id) }
    }

    private static func identifiers(from req: Request) throws -> (UUID, UUID) {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or folder ID")
        }
        return (organizationID, ouID)
    }

    private static func tree(
        rootID: UUID,
        from subtree: [OrganizationalUnitOverview]
    ) -> OrganizationalUnitTreeResponse {
        let byID = Dictionary(
            uniqueKeysWithValues: subtree.map { ($0.organizationalUnit.id, $0) }
        )
        var childrenByParent: [UUID: [OrganizationalUnitOverview]] = [:]
        for folder in subtree where folder.organizationalUnit.id != rootID {
            guard let parentID = folder.organizationalUnit.parentID else { continue }
            childrenByParent[parentID, default: []].append(folder)
        }

        func assemble(_ folder: OrganizationalUnitOverview) -> OrganizationalUnitTreeResponse {
            let snapshot = folder.organizationalUnit
            let children = (childrenByParent[snapshot.id] ?? []).sorted {
                if $0.organizationalUnit.name == $1.organizationalUnit.name {
                    return $0.organizationalUnit.id.uuidString < $1.organizationalUnit.id.uuidString
                }
                return $0.organizationalUnit.name < $1.organizationalUnit.name
            }
            return OrganizationalUnitTreeResponse(
                id: snapshot.id,
                name: snapshot.name,
                description: snapshot.description,
                path: snapshot.path,
                depth: snapshot.depth,
                projectCount: folder.projectCount,
                children: children.map(assemble)
            )
        }

        return assemble(byID[rootID]!)
    }
}

private extension OrganizationalUnitResponse {
    init(from overview: OrganizationalUnitOverview) {
        let folder = overview.organizationalUnit
        self.id = folder.id
        self.name = folder.name
        self.description = folder.description
        self.organizationId = folder.organizationID
        self.parentOuId = folder.parentID
        self.path = folder.path
        self.depth = folder.depth
        self.createdAt = folder.createdAt
        self.childOuCount = overview.childCount
        self.projectCount = overview.projectCount
    }
}

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
