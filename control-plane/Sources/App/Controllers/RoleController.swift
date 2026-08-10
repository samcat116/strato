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

    /// One action of the catalog, with everything the role editor needs to
    /// place it (issue #605).
    struct ActionCatalogEntry: Content, Equatable, Sendable {
        let action: String
        let service: String
        /// The tree-node types this action can be requested against, in wire
        /// naming (`virtual_machine`, `organizational_unit`, …). Container
        /// types appear because `create`/`list` checks target the container.
        let resourceTypes: [String]
        /// The seeded roles whose action group carries this action. Empty for
        /// an action no default role grants — which is a fine thing for a
        /// custom role to grant, and worth showing as such.
        let roles: [String]
        /// Granted by bare organization membership, with no binding behind it
        /// (`IAMRoleRegistry.membershipDerivedActions`). Including such an
        /// action in a custom role is legal but buys nothing inside the org.
        let membershipDerived: Bool
    }

    /// The actions of one service, the grouping the editor renders.
    struct ActionServiceGroup: Content, Equatable, Sendable {
        let service: String
        let actions: [ActionCatalogEntry]
    }

    struct ActionCatalogResponse: Content, Equatable, Sendable {
        let services: [ActionServiceGroup]
    }

    // MARK: - Routes

    /// GET /api/iam/roles?ownerType=&ownerId=
    ///
    /// The roles a single owner defines. The bindable set at a node — which
    /// includes the platform defaults and everything inherited — is
    /// `bindable`.
    func list(req: Request) async throws -> RoleListResponse {
        _ = try req.auth.require(User.self)
        guard let ownerType = req.query[String.self, at: "ownerType"],
            let ownerId = req.query[String.self, at: "ownerId"]
        else {
            throw Abort(.badRequest, reason: "ownerType and ownerId query parameters are required")
        }
        let owner = try IAMPolicySetOwner(type: ownerType, id: ownerId, kind: .role)
        try await owner.requirePolicyAdmin(write: false, req: req)

        let roles = try await RoleStore.owned(by: owner.type, ownerID: owner.id, on: req.db)
        return RoleListResponse(roles: try roles.map(RoleDTO.init))
    }

    /// GET /api/iam/roles/:roleID
    func get(req: Request) async throws -> RoleDTO {
        _ = try req.auth.require(User.self)
        let role = try await find(req)
        // Platform rows are the seeded defaults: public knowledge, and the
        // same content `bindable` and the catalog already hand out.
        if let owner = try owner(of: role) {
            try await owner.requirePolicyAdmin(write: false, req: req)
        }
        return try RoleDTO(role)
    }

    /// POST /api/iam/roles
    func create(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let payload = try req.content.decode(CreateRoleRequest.self)
        let owner = try IAMPolicySetOwner(creating: payload.ownerType, id: payload.ownerId, kind: .role)
        try await owner.requireExists(on: req.db)
        try await owner.requirePolicyAdmin(write: true, req: req)

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
        let user = try req.auth.require(User.self)
        let existing = try await find(req)
        try requireUnmanaged(existing)
        guard let owner = try owner(of: existing), let id = existing.id else {
            throw RoleError.managedRoleImmutable(existing.name)
        }
        try await owner.requirePolicyAdmin(write: true, req: req)

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
        let user = try req.auth.require(User.self)
        let role = try await find(req)
        try requireUnmanaged(role)
        guard let owner = try owner(of: role), let id = role.id else {
            throw RoleError.managedRoleImmutable(role.name)
        }
        try await owner.requirePolicyAdmin(write: true, req: req)

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
        _ = try req.auth.require(User.self)
        try await req.markRowScopedAuthorization()
        let payload = try req.content.decode(ValidateRoleRequest.self)
        let id = payload.id ?? UUID()
        let prepared = try await prepare(
            id: id, actions: payload.actions, cedarText: payload.cedarText, req: req)
        return ValidateRoleResponse(id: id, cedarText: prepared.cedarText, actions: prepared.actions)
    }

    /// GET /api/iam/roles/bindable?nodeType=&nodeId=
    func bindable(req: Request) async throws -> BindableRolesResponse {
        _ = try req.auth.require(User.self)
        guard let nodeType = req.query[String.self, at: "nodeType"],
            let nodeId = req.query[String.self, at: "nodeId"]
        else {
            throw Abort(.badRequest, reason: "nodeType and nodeId query parameters are required")
        }
        let node = try IAMNode(resourceType: nodeType, resourceId: nodeId)
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
    func actions(req: Request) async throws -> ActionCatalogResponse {
        _ = try req.auth.require(User.self)
        return Self.actionCatalog()
    }

    // MARK: - Helpers

    /// The whole action catalog, sorted so two calls — and two deployments —
    /// agree. Static: it is generated from `IAMRoleRegistry` and
    /// `CedarSchemaBuilder`, the same two places the Cedar schema comes from,
    /// so the picker in the UI can never offer an action the write path would
    /// reject — or omit one it would accept.
    private static func actionCatalog() -> ActionCatalogResponse {
        let entries = IAMRoleRegistry.allActions.sorted().map(catalogEntry(for:))
        let grouped = Dictionary(grouping: entries, by: \.service)
        return ActionCatalogResponse(
            services: grouped.keys.sorted().map { service in
                ActionServiceGroup(service: service, actions: grouped[service] ?? [])
            })
    }

    private static func catalogEntry(for action: String) -> ActionCatalogEntry {
        let service = action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action
        let cedarTypes = Set(CedarSchemaBuilder.resourceTypes(for: action).map(\.rawValue))
        return ActionCatalogEntry(
            action: action,
            service: service,
            resourceTypes: IAMNodeType.allCases
                .filter { cedarTypes.contains($0.cedarEntityType.rawValue) }
                .map(\.rawValue)
                .sorted(),
            roles: IAMRoleRegistry.roles(granting: action).map(\.rawValue).sorted(),
            membershipDerived: IAMRoleRegistry.membershipDerivedActions.contains(action)
        )
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
    private func owner(of role: IAMRoleDefinition) throws -> IAMPolicySetOwner? {
        guard let type = IAMRoleOwnerType(rawValue: role.ownerType) else {
            throw Abort(.internalServerError, reason: "Role row names an unknown owner type '\(role.ownerType)'")
        }
        guard type != .platform else { return nil }
        return IAMPolicySetOwner(type: type, id: role.ownerID, kind: .role)
    }

    private func requireUnmanaged(_ role: IAMRoleDefinition) throws {
        guard !role.managed else { throw RoleError.managedRoleImmutable(role.name) }
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

    /// The node's own canonical read action — `project:read` for a project,
    /// `vm:read` for a VM, and so on.
    private func requireNodeRead(_ node: IAMNode, req: Request) async throws {
        guard try await req.can(node.type.readAction, on: node) else {
            throw Abort(.forbidden, reason: "Listing the roles bindable here requires read access to it")
        }
    }
}
