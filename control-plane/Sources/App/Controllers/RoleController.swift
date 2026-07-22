import Fluent
import Vapor

/// The role-definition API (issue #605): creating and editing the roles a
/// binding can name.
///
/// Same guardrail-controller posture, for the same reason — a role is policy,
/// not data. Every write is `iam:setPolicy` on the role's owner, runs inside
/// `withPolicySetChange` so the row and its version bump commit together, and
/// announces the change so every replica recompiles. Reading a role is
/// `iam:readPolicy`: what a role grants is a statement about who can do what.
///
/// The exception is `bindable`, which is gated on the node's own `read` action
/// instead. Choosing a role to grant is part of the grant flow, and someone
/// who can see a project needs to see what is grantable there without being an
/// admin of it. That weaker gate is why it answers in `BindableRoleDTO` rather
/// than `RoleDTO`: names and action sets — which the catalog already publishes
/// — and not the policy text, which can describe the org's security posture
/// and stays an `iam:readPolicy` act to read.
struct RoleController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let iam = routes.grouped("api", "iam")

        let roles = iam.grouped("roles")
        roles.get(use: list)
        roles.post(use: create)
        // Static segments before the parameter: Vapor's router prefers the
        // literal, so neither of these is ever read as a role id.
        roles.post("validate", use: validate)
        roles.get("bindable", use: bindable)
        roles.group(":roleID") { role in
            role.get(use: get)
            role.patch(use: update)
            role.delete(use: delete)
        }

        iam.get("actions", use: actions)
    }

    // MARK: - DTOs

    struct RoleDTO: Content {
        let id: UUID
        let name: String
        let description: String?
        let ownerType: IAMRoleOwnerType
        let ownerId: UUID
        /// The role's permit. Round-trips: what comes back here is accepted
        /// verbatim as `cedarText` on a later write.
        let cedarText: String
        /// Derived from `cedarText`'s action scope, never sent by the client.
        let actions: [String]
        /// Seeded and reconciled by the deployment; immutable through the API.
        let managed: Bool
        let createdBy: UUID?
        let createdAt: Date?
        let updatedAt: Date?

        init(_ role: IAMRoleDefinition) throws {
            guard let id = role.id, let ownerType = IAMRoleOwnerType(rawValue: role.ownerType) else {
                throw Abort(.internalServerError, reason: "Role row is missing its id or names an unknown owner type")
            }
            self.id = id
            self.name = role.name
            self.description = role.description
            self.ownerType = ownerType
            self.ownerId = role.ownerID
            self.cedarText = role.cedarText
            self.actions = role.actions
            self.managed = role.managed
            self.createdBy = role.createdBy
            self.createdAt = role.createdAt
            self.updatedAt = role.updatedAt
        }
    }

    struct CreateRoleRequest: Content {
        let name: String
        let description: String?
        let ownerType: IAMRoleOwnerType
        let ownerId: UUID
        /// Pick actions and the server writes the canonical permit…
        let actions: [String]?
        /// …or write the permit yourself. Exactly one of the two.
        ///
        /// Advanced text is conditioned on the role's own grants fields, whose
        /// names embed the role id — so a client writing its own text supplies
        /// the id too (`POST /api/iam/roles/validate` hands out one to build
        /// against). Omitted, the server allocates it and the action-list mode
        /// is the only one that can be used.
        let cedarText: String?
        let id: UUID?
    }

    struct UpdateRoleRequest: Content {
        let name: String?
        let description: String?
        let actions: [String]?
        let cedarText: String?
    }

    /// `POST /api/iam/roles/validate` — compile without saving.
    struct ValidateRoleRequest: Content {
        let actions: [String]?
        let cedarText: String?
        /// The role being edited, so its own grants fields are the accepted
        /// ones. Omitted for a role that does not exist yet.
        let id: UUID?
    }

    struct ValidateRoleResponse: Content {
        /// The id the text was checked against — the one being edited, or a
        /// freshly allocated one to write `cedarText` against and then send
        /// back as `CreateRoleRequest.id`.
        let id: UUID
        let cedarText: String
        let actions: [String]
    }

    struct RoleListResponse: Content {
        let roles: [RoleDTO]
    }

    /// A role as the *grant* flow needs to see it: enough to choose one and
    /// know what it confers, and no policy text.
    ///
    /// Deliberately not `RoleDTO`. This listing is gated on read of the node
    /// rather than on `iam:readPolicy`, so it reaches a wider audience than
    /// the role API proper — and a role's `cedarText` can carry conditions
    /// that describe the org's security posture (which environments are
    /// fenced off, where MFA is demanded). Names and action sets are what
    /// choosing a role requires, and are already public via the catalog; the
    /// policy text is not, and reading it stays an `iam:readPolicy` act.
    struct BindableRoleDTO: Content {
        let id: UUID
        let name: String
        let description: String?
        let ownerType: IAMRoleOwnerType
        let ownerId: UUID
        let actions: [String]
        let managed: Bool

        init(_ role: IAMRoleDefinition) throws {
            guard let id = role.id, let ownerType = IAMRoleOwnerType(rawValue: role.ownerType) else {
                throw Abort(.internalServerError, reason: "Role row is missing its id or names an unknown owner type")
            }
            self.id = id
            self.name = role.name
            self.description = role.description
            self.ownerType = ownerType
            self.ownerId = role.ownerID
            self.actions = role.actions
            self.managed = role.managed
        }
    }

    struct BindableRolesResponse: Content {
        let node: IAMNode
        /// The chain the answer was assembled from, resource first, so an
        /// inherited role is explicable without a second round trip.
        let ancestors: [IAMNode]
        let roles: [BindableRoleDTO]
    }

    // MARK: - Routes

    /// GET /api/iam/roles?ownerType=&ownerId=
    ///
    /// The roles a single owner defines. The bindable set at a node — which
    /// includes the platform defaults and everything inherited — is
    /// `bindable`.
    func list(req: Request) async throws -> RoleListResponse {
        _ = try requireUser(req)
        guard let ownerType = req.query[String.self, at: "ownerType"],
            let ownerId = req.query[String.self, at: "ownerId"]
        else {
            throw Abort(.badRequest, reason: "ownerType and ownerId query parameters are required")
        }
        let owner = try RoleOwner(type: ownerType, id: ownerId)
        try await requirePolicyAdmin(on: owner.node, write: false, req: req)

        let roles = try await RoleStore.owned(by: owner.type, ownerID: owner.id, on: req.db)
        return RoleListResponse(roles: try roles.map(RoleDTO.init))
    }

    /// GET /api/iam/roles/:roleID
    func get(req: Request) async throws -> RoleDTO {
        _ = try requireUser(req)
        let role = try await find(req)
        // Platform rows are the seeded defaults: public knowledge, and the
        // same content `bindable` and the catalog already hand out.
        if let owner = try owner(of: role) {
            try await requirePolicyAdmin(on: owner.node, write: false, req: req)
        }
        return try RoleDTO(role)
    }

    /// POST /api/iam/roles
    func create(req: Request) async throws -> Response {
        let user = try requireUser(req)
        let payload = try req.content.decode(CreateRoleRequest.self)
        guard RoleStore.creatableOwnerTypes.contains(payload.ownerType) else {
            throw RoleError.uncreatableOwnerType(payload.ownerType.rawValue)
        }
        let owner = RoleOwner(type: payload.ownerType, id: payload.ownerId)
        try await requireOwnerExists(owner, on: req.db)
        try await requirePolicyAdmin(on: owner.node, write: true, req: req)

        let id = payload.id ?? UUID()
        let prepared = try await prepare(
            id: id, actions: payload.actions, cedarText: payload.cedarText, req: req)

        let role = try await PolicySetVersionService.withPolicySetChange(on: req.db) { db in
            let role = try await RoleStore.create(
                id: id,
                name: payload.name,
                description: payload.description,
                ownerType: owner.type,
                ownerID: owner.id,
                prepared: prepared,
                createdBy: user.id,
                on: db
            )
            try await PolicySetVersionService.bump(
                reason: "role created: \(payload.name)", changedBy: user.id, on: db)
            return role
        }
        await req.application.announcePolicySetChange()

        let response = Response(status: .created)
        try response.content.encode(try RoleDTO(role))
        return response
    }

    /// PATCH /api/iam/roles/:roleID
    func update(req: Request) async throws -> RoleDTO {
        let user = try requireUser(req)
        let existing = try await find(req)
        try requireUnmanaged(existing)
        guard let owner = try owner(of: existing), let id = existing.id else {
            throw RoleError.managedRoleImmutable(existing.name)
        }
        try await requirePolicyAdmin(on: owner.node, write: true, req: req)

        let payload = try req.content.decode(UpdateRoleRequest.self)
        // A body that touches neither the permit nor the labels is a no-op
        // request, not a version bump.
        let rewritesPermit = payload.actions != nil || payload.cedarText != nil
        let prepared =
            rewritesPermit
            ? try await prepare(id: id, actions: payload.actions, cedarText: payload.cedarText, req: req)
            : nil

        let name = payload.name ?? existing.name
        let updated = try await PolicySetVersionService.withPolicySetChange(on: req.db) { db in
            // Re-read inside the transaction so the edit and the bump see the
            // same row, and a retried attempt starts from the row as it is now.
            guard let role = try await IAMRoleDefinition.find(id, on: db) else {
                throw Abort(.notFound, reason: "Role not found")
            }
            try requireUnmanaged(role)
            if let newName = payload.name { role.name = newName }
            if let description = payload.description { role.description = description }
            if let prepared {
                role.cedarText = prepared.cedarText
                role.actions = prepared.actions
            }
            do {
                try await role.save(on: db)
            } catch let error as any DatabaseError where error.isConstraintFailure {
                throw RoleError.duplicateName(name)
            }
            try await PolicySetVersionService.bump(
                reason: "role updated: \(name)", changedBy: user.id, on: db)
            return role
        }
        await req.application.announcePolicySetChange()

        return try RoleDTO(updated)
    }

    /// DELETE /api/iam/roles/:roleID
    func delete(req: Request) async throws -> HTTPStatus {
        let user = try requireUser(req)
        let role = try await find(req)
        try requireUnmanaged(role)
        guard let owner = try owner(of: role), let id = role.id else {
            throw RoleError.managedRoleImmutable(role.name)
        }
        try await requirePolicyAdmin(on: owner.node, write: true, req: req)

        // Refused rather than cascaded: dropping a role out from under live
        // bindings would silently revoke whatever they grant, with nothing in
        // the bindings list to show it happened.
        let bindings = try await RoleStore.activeBindingCount(roleID: id, on: req.db)
        guard bindings == 0 else { throw RoleError.roleInUse(role.name, bindings) }

        let name = role.name
        try await PolicySetVersionService.withPolicySetChange(on: req.db) { db in
            try await IAMRoleDefinition.query(on: db).filter(\.$id == id).delete()
            try await PolicySetVersionService.bump(
                reason: "role deleted: \(name)", changedBy: user.id, on: db)
        }
        await req.application.announcePolicySetChange()

        return .noContent
    }

    /// POST /api/iam/roles/validate
    ///
    /// The editor's compile button: the same preparation a write does, minus
    /// the write. Callers get the generated (or accepted) text and the derived
    /// action list back, so the editor can show what a role will actually
    /// grant before anyone commits to it.
    ///
    /// Authenticated but not admin-gated: it touches no stored policy, and the
    /// vocabulary it validates against is what `GET /api/iam/actions` already
    /// publishes. Gating it on an owner would make the editor pick a home for
    /// a role before it could check whether the role even compiles, for no
    /// secret kept — so this is a POST that deliberately evaluates nothing,
    /// declared as such rather than tripping the default-deny middleware's
    /// "mutating handler forgot its check" assertion.
    func validate(req: Request) async throws -> ValidateRoleResponse {
        _ = try requireUser(req)
        req.markRowScopedAuthorization()
        let payload = try req.content.decode(ValidateRoleRequest.self)
        let id = payload.id ?? UUID()
        let prepared = try await prepare(
            id: id, actions: payload.actions, cedarText: payload.cedarText, req: req)
        return ValidateRoleResponse(id: id, cedarText: prepared.cedarText, actions: prepared.actions)
    }

    /// GET /api/iam/roles/bindable?nodeType=&nodeId=
    func bindable(req: Request) async throws -> BindableRolesResponse {
        _ = try requireUser(req)
        guard let nodeType = req.query[String.self, at: "nodeType"],
            let nodeId = req.query[String.self, at: "nodeId"]
        else {
            throw Abort(.badRequest, reason: "nodeType and nodeId query parameters are required")
        }
        let node = try IAMPolicyGate.node(resourceType: nodeType, resourceId: nodeId)
        try await requireNodeRead(node, req: req)

        let ancestors = try await IAMResourceTree.ancestors(of: node, on: req.db)
        let roles = try await RoleStore.bindable(along: ancestors, on: req.db)
        return BindableRolesResponse(
            node: node, ancestors: ancestors, roles: try roles.map(BindableRoleDTO.init))
    }

    /// GET /api/iam/actions
    ///
    /// The action vocabulary, generated from the registry. Authenticated only:
    /// it describes the software, not any deployment's policy.
    func actions(req: Request) async throws -> IAMActionCatalog.Response {
        _ = try requireUser(req)
        return IAMActionCatalog.catalog()
    }

    // MARK: - Helpers

    /// A role's owner as both halves it is used as: the store's
    /// `(ownerType, ownerID)` pair and the tree node the gates run on.
    private struct RoleOwner {
        let type: IAMRoleOwnerType
        let id: UUID

        var node: IAMNode {
            // Every creatable owner type has a node type; the platform
            // sentinel is refused before this is reached.
            IAMNode(type: type.nodeType ?? .organization, id: id)
        }

        init(type: IAMRoleOwnerType, id: UUID) {
            self.type = type
            self.id = id
        }

        init(type: String, id: String) throws {
            guard let ownerType = IAMRoleOwnerType(rawValue: type),
                RoleStore.creatableOwnerTypes.contains(ownerType)
            else {
                throw RoleError.uncreatableOwnerType(type)
            }
            guard let ownerID = UUID(uuidString: id) else {
                throw Abort(.badRequest, reason: "Role owner id must be a UUID")
            }
            self.init(type: ownerType, id: ownerID)
        }
    }

    private func requireUser(_ req: Request) throws -> User {
        guard let user = req.auth.get(User.self) else { throw Abort(.unauthorized) }
        return user
    }

    private func find(_ req: Request) async throws -> IAMRoleDefinition {
        guard let id = req.parameters.get("roleID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Role id must be a UUID")
        }
        guard let role = try await IAMRoleDefinition.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Role not found")
        }
        return role
    }

    /// The owner of a role, or nil for a platform row (which has no node to
    /// gate on and no owner to scope it to).
    private func owner(of role: IAMRoleDefinition) throws -> RoleOwner? {
        guard let type = IAMRoleOwnerType(rawValue: role.ownerType) else {
            throw Abort(.internalServerError, reason: "Role row names an unknown owner type '\(role.ownerType)'")
        }
        guard type != .platform else { return nil }
        return RoleOwner(type: type, id: role.ownerID)
    }

    private func requireUnmanaged(_ role: IAMRoleDefinition) throws {
        guard !role.managed else { throw RoleError.managedRoleImmutable(role.name) }
    }

    /// A role scoped to an owner that does not exist would be bindable
    /// nowhere, so this is a `404` at the boundary rather than an orphan row.
    private func requireOwnerExists(_ owner: RoleOwner, on db: any Database) async throws {
        let exists: Bool
        switch owner.type {
        case .organization:
            exists = try await Organization.find(owner.id, on: db) != nil
        case .project:
            exists = try await Project.find(owner.id, on: db) != nil
        case .platform:
            exists = false
        }
        guard exists else {
            throw RoleError.unknownOwner("\(owner.type.rawValue)/\(owner.id)")
        }
    }

    private func prepare(
        id: UUID, actions: [String]?, cedarText: String?, req: Request
    ) async throws -> RoleStore.Prepared {
        let existing = try await RoleStore.allDescriptors(on: req.db)
        return try RoleStore.prepare(
            id: id,
            actions: actions,
            cedarText: cedarText,
            existingRoles: existing,
            engine: req.application.cedarEngine
        )
    }

    /// Reading and writing a role is `iam:readPolicy` / `iam:setPolicy` on its
    /// owner — the same gate guardrails use, for the same reason.
    private func requirePolicyAdmin(on node: IAMNode, write: Bool, req: Request) async throws {
        let reason = "Managing roles requires admin on the role's owner or a container above it"
        if write {
            try await IAMPolicyGate.requirePolicyWrite(on: node, deniedReason: reason, req: req)
        } else {
            try await IAMPolicyGate.requirePolicyRead(on: node, deniedReason: reason, req: req)
        }
    }

    /// The node's own read action — `project:read` for a project, `vm:read`
    /// for a VM, and so on. Derived from the translator so a new node type
    /// gets its gate from the same mapping the rest of the API uses.
    private func requireNodeRead(_ node: IAMNode, req: Request) async throws {
        guard
            let action = IAMActionTranslator.translate(
                permission: "read", resourceType: node.type.rawValue, resourceID: node.id.uuidString, path: ""
            )?.action
        else {
            throw Abort(.badRequest, reason: "No read action is defined for '\(node.type.rawValue)'")
        }
        guard try await req.can(action, on: node) else {
            throw Abort(.forbidden, reason: "Listing the roles bindable here requires read access to it")
        }
    }
}
