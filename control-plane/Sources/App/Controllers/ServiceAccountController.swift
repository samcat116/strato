import Fluent
import Foundation
import Vapor

/// Service accounts (issue #491): project-scoped machine principals, plus the
/// workload registrations mapping SPIFFE identities to them.
///
/// A service account is a resource in the IAM tree (`serviceaccount:*`
/// actions under its project, including `impersonate`) *and* a principal —
/// its project role is an ordinary `role_bindings` row written through the
/// same guardrail-checked path user and group grants use.
struct ServiceAccountController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let projectScoped = routes.grouped("api", "projects", ":projectID", "service-accounts")
        projectScoped.get(use: list)
        projectScoped.post(use: create)

        let accounts = routes.grouped("api", "service-accounts", ":serviceAccountID")
        accounts.get(use: read)
        accounts.patch(use: update)
        accounts.delete(use: delete)
        accounts.put("project-role", use: setProjectRole)
        accounts.delete("project-role", use: clearProjectRole)
        accounts.get("registrations", use: listRegistrations)
        accounts.post("registrations", use: createRegistration)
        accounts.delete("registrations", ":registrationID", use: deleteRegistration)
    }

    // MARK: - DTOs

    struct ServiceAccountResponse: Content {
        let id: UUID
        let name: String
        let description: String
        let projectId: UUID
        /// The seeded roles the account holds on its project, from its active
        /// bindings (normally zero or one).
        let projectRoles: [String]
        let createdAt: Date?
        let updatedAt: Date?
    }

    struct CreateServiceAccountRequest: Content {
        let name: String
        let description: String?
    }

    struct UpdateServiceAccountRequest: Content {
        let description: String?
    }

    struct SetProjectRoleRequest: Content {
        /// A seeded role name: viewer, operator, editor, or admin.
        let role: String
    }

    struct WorkloadRegistrationResponse: Content {
        let id: UUID
        let spiffeId: String
        let kind: String
        let agentName: String?
        let serviceAccountId: UUID?
        let organizationId: UUID?
        let displayName: String?
        let createdAt: Date?

        init(_ row: WorkloadRegistration) throws {
            self.id = try row.requireID()
            self.spiffeId = row.spiffeID
            self.kind = row.kind.rawValue
            self.agentName = row.agentName
            self.serviceAccountId = row.$serviceAccount.id
            self.organizationId = row.$organization.id
            self.displayName = row.displayName
            self.createdAt = row.createdAt
        }
    }

    struct CreateRegistrationRequest: Content {
        let spiffeId: String
    }

    // MARK: - CRUD

    /// GET /api/projects/:projectID/service-accounts
    func list(req: Request) async throws -> [ServiceAccountResponse] {
        let project = try await loadProject(req)
        let projectID = try project.requireID()
        try await req.authorize("serviceaccount:list", on: IAMNode(type: .project, id: projectID))

        let accounts = try await ServiceAccount.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .sort(\.$name)
            .all()
        let rolesByAccount = try await projectRolesByAccount(
            accountIDs: accounts.compactMap(\.id), projectID: projectID, on: req.db)
        return try accounts.map { account in
            let id = try account.requireID()
            return response(account, id: id, projectID: projectID, projectRoles: rolesByAccount[id] ?? [])
        }
    }

    /// POST /api/projects/:projectID/service-accounts
    func create(req: Request) async throws -> Response {
        let project = try await loadProject(req)
        let projectID = try project.requireID()
        try await req.authorize("serviceaccount:create", on: IAMNode(type: .project, id: projectID))

        let body = try req.content.decode(CreateServiceAccountRequest.self)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 128 else {
            throw Abort(.badRequest, reason: "Service account name must be 1-128 characters")
        }

        let existing = try await ServiceAccount.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .filter(\.$name == name)
            .first()
        guard existing == nil else {
            throw Abort(.conflict, reason: "A service account with this name already exists in the project")
        }

        let account = ServiceAccount(name: name, description: body.description ?? "", projectID: projectID)
        let actorID = req.auth.get(User.self)?.id
        try await req.db.transaction { db in
            try await account.save(on: db)
            // The creator's explicit, revocable binding on the account, in
            // the create transaction (docs/architecture/iam.md: creating a
            // resource writes an ordinary binding for the creator).
            if let actorID {
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: actorID,
                    role: .admin,
                    nodeType: .serviceAccount,
                    nodeID: account.requireID(),
                    createdBy: actorID,
                    on: db
                )
            }
        }

        let payload = try response(account, id: account.requireID(), projectID: projectID, projectRoles: [])
        let response = Response(status: .created)
        try response.content.encode(payload)
        return response
    }

    /// GET /api/service-accounts/:serviceAccountID
    func read(req: Request) async throws -> ServiceAccountResponse {
        let account = try await loadAccount(req)
        let accountID = try account.requireID()
        try await req.authorize("serviceaccount:read", on: IAMNode(type: .serviceAccount, id: accountID))
        let roles = try await projectRolesByAccount(
            accountIDs: [accountID], projectID: account.$project.id, on: req.db)
        return response(
            account, id: accountID, projectID: account.$project.id, projectRoles: roles[accountID] ?? [])
    }

    /// PATCH /api/service-accounts/:serviceAccountID
    func update(req: Request) async throws -> ServiceAccountResponse {
        let account = try await loadAccount(req)
        let accountID = try account.requireID()
        try await req.authorize("serviceaccount:update", on: IAMNode(type: .serviceAccount, id: accountID))

        let body = try req.content.decode(UpdateServiceAccountRequest.self)
        if let description = body.description {
            account.accountDescription = description
        }
        try await account.save(on: req.db)
        let roles = try await projectRolesByAccount(
            accountIDs: [accountID], projectID: account.$project.id, on: req.db)
        return response(
            account, id: accountID, projectID: account.$project.id, projectRoles: roles[accountID] ?? [])
    }

    /// DELETE /api/service-accounts/:serviceAccountID
    func delete(req: Request) async throws -> HTTPStatus {
        let account = try await loadAccount(req)
        let accountID = try account.requireID()
        try await req.authorize("serviceaccount:delete", on: IAMNode(type: .serviceAccount, id: accountID))

        try await req.db.transaction { db in
            // Registrations cascade with the row; the bindings need explicit
            // cleanup on both sides — those attached *to* the account (it is
            // a node) and those *held by* it (it is a principal). Leaving the
            // held bindings behind would let a recreated principal id (never,
            // with UUIDs, but the offboarding rule stands) inherit them.
            try await RoleBindingService.revokeAll(nodeType: .serviceAccount, nodeID: accountID, on: db)
            for binding in try await RoleBindingService.activeBindings(
                principalType: .serviceAccount, principalID: accountID, on: db)
            {
                try await binding.delete(on: db)
            }
            try await account.delete(on: db)
        }
        return .noContent
    }

    // MARK: - Project role

    /// PUT /api/service-accounts/:serviceAccountID/project-role — grant the
    /// account a seeded role on its project, replacing any existing one. This
    /// is an IAM policy write on the project, gated and guardrail-checked
    /// exactly like user and group grants.
    func setProjectRole(req: Request) async throws -> HTTPStatus {
        let account = try await loadAccount(req)
        let accountID = try account.requireID()
        let projectID = account.$project.id
        try await req.authorize("iam:setPolicy", on: IAMNode(type: .project, id: projectID))

        let body = try req.content.decode(SetProjectRoleRequest.self)
        guard let role = IAMRole(rawValue: body.role) else {
            throw Abort(.badRequest, reason: "Invalid role; must be one of: viewer, operator, editor, admin")
        }

        // A ceiling in force on this project (or above it) may forbid what
        // this grant would reach — refuse now, with the reason (#484).
        try await GuardrailWriteCheck.requireNoViolation(
            ProposedBinding(
                principalType: .serviceAccount,
                principalID: accountID,
                role: role,
                node: IAMNode(type: .project, id: projectID)
            ), req: req)

        let actorID = req.auth.get(User.self)?.id
        try await req.db.transaction { db in
            // Replace, not accumulate: one project role per account, the same
            // shape the member endpoints keep for users.
            try await RoleBindingService.revoke(
                principalType: .serviceAccount,
                principalID: accountID,
                nodeType: .project,
                nodeID: projectID,
                on: db
            )
            try await RoleBindingService.grant(
                principalType: .serviceAccount,
                principalID: accountID,
                role: role,
                nodeType: .project,
                nodeID: projectID,
                createdBy: actorID,
                on: db
            )
        }
        return .ok
    }

    /// DELETE /api/service-accounts/:serviceAccountID/project-role
    func clearProjectRole(req: Request) async throws -> HTTPStatus {
        let account = try await loadAccount(req)
        let accountID = try account.requireID()
        let projectID = account.$project.id
        try await req.authorize("iam:setPolicy", on: IAMNode(type: .project, id: projectID))

        try await RoleBindingService.revoke(
            principalType: .serviceAccount,
            principalID: accountID,
            nodeType: .project,
            nodeID: projectID,
            on: req.db
        )
        return .noContent
    }

    // MARK: - Workload registrations

    /// GET /api/service-accounts/:serviceAccountID/registrations
    func listRegistrations(req: Request) async throws -> [WorkloadRegistrationResponse] {
        let account = try await loadAccount(req)
        let accountID = try account.requireID()
        try await req.authorize("serviceaccount:read", on: IAMNode(type: .serviceAccount, id: accountID))

        return try await WorkloadRegistration.query(on: req.db)
            .filter(\.$serviceAccount.$id == accountID)
            .sort(\.$spiffeID)
            .all()
            .map(WorkloadRegistrationResponse.init)
    }

    /// POST /api/service-accounts/:serviceAccountID/registrations — register
    /// a SPIFFE identity as authenticating to this account. The identity is a
    /// lookup key only; nothing is ever parsed out of it.
    func createRegistration(req: Request) async throws -> Response {
        let account = try await loadAccount(req)
        let accountID = try account.requireID()
        try await req.authorize("serviceaccount:update", on: IAMNode(type: .serviceAccount, id: accountID))

        let body = try req.content.decode(CreateRegistrationRequest.self)
        guard SPIFFEIdentity(uri: body.spiffeId) != nil else {
            throw Abort(.badRequest, reason: "Not a valid SPIFFE URI (spiffe://<trust-domain>/<path>)")
        }

        let registration = WorkloadRegistration(
            spiffeID: body.spiffeId,
            kind: .serviceAccount,
            serviceAccountID: accountID,
            createdBy: req.auth.get(User.self)?.id
        )
        do {
            try await registration.save(on: req.db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // One identity, one principal: the registry is a function.
            throw Abort(.conflict, reason: "This SPIFFE ID is already registered")
        }

        let response = Response(status: .created)
        try response.content.encode(try WorkloadRegistrationResponse(registration))
        return response
    }

    /// DELETE /api/service-accounts/:serviceAccountID/registrations/:registrationID
    func deleteRegistration(req: Request) async throws -> HTTPStatus {
        let account = try await loadAccount(req)
        let accountID = try account.requireID()
        try await req.authorize("serviceaccount:update", on: IAMNode(type: .serviceAccount, id: accountID))

        guard let registrationID = req.parameters.get("registrationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid registration ID")
        }
        guard
            let registration = try await WorkloadRegistration.query(on: req.db)
                .filter(\.$id == registrationID)
                .filter(\.$serviceAccount.$id == accountID)
                .first()
        else {
            throw Abort(.notFound, reason: "Registration not found")
        }
        try await registration.delete(on: req.db)
        return .noContent
    }

    // MARK: - Helpers

    private func response(
        _ account: ServiceAccount, id: UUID, projectID: UUID, projectRoles: [String]
    ) -> ServiceAccountResponse {
        ServiceAccountResponse(
            id: id,
            name: account.name,
            description: account.accountDescription,
            projectId: projectID,
            projectRoles: projectRoles,
            createdAt: account.createdAt,
            updatedAt: account.updatedAt
        )
    }

    /// The seeded role names each account holds on the project, from its
    /// active bindings. Custom-role bindings are not representable in this
    /// summary and are omitted; the who-can API reports them.
    private func projectRolesByAccount(
        accountIDs: [UUID], projectID: UUID, on db: any Database
    ) async throws -> [UUID: [String]] {
        guard !accountIDs.isEmpty else { return [:] }
        let bindings = try await RoleBinding.query(on: db)
            .filter(\.$principalType == IAMPrincipalType.serviceAccount.rawValue)
            .filter(\.$principalID ~~ accountIDs)
            .filter(\.$nodeType == IAMNodeType.project.rawValue)
            .filter(\.$nodeID == projectID)
            .active()
            .all()
        var roles: [UUID: [String]] = [:]
        for binding in bindings {
            guard
                let roleID = UUID(uuidString: binding.role),
                let role = IAMRole(seededID: roleID)
            else { continue }
            roles[binding.principalID, default: []].append(role.rawValue)
        }
        return roles.mapValues { $0.sorted() }
    }

    private func loadProject(_ req: Request) async throws -> Project {
        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }
        guard let project = try await Project.find(projectID, on: req.db) else {
            throw Abort(.notFound, reason: "Project not found")
        }
        return project
    }

    private func loadAccount(_ req: Request) async throws -> ServiceAccount {
        guard let accountID = req.parameters.get("serviceAccountID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid service account ID")
        }
        guard let account = try await ServiceAccount.find(accountID, on: req.db) else {
            throw Abort(.notFound, reason: "Service account not found")
        }
        return account
    }
}
