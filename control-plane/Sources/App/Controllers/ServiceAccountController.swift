import ControlPlanePostgres
import Foundation
import Vapor

/// Service accounts (issue #491): project-scoped machine principals, plus the
/// workload registrations mapping SPIFFE identities to them.
///
/// A service account is a resource in the IAM tree (`serviceaccount:*`
/// actions under its project, including `impersonate`) *and* a principal —
/// its project role is an ordinary `role_bindings` row written through the
/// same ceiling-reported path user and group grants use.
struct ServiceAccountController: RouteCollection {
    private let serviceAccounts: ServiceAccountsPersistence
    private let workloads: WorkloadsPersistence
    private let projects: ProjectsPersistence
    private let iam: IAMPersistence
    private let groups: GroupsPersistence
    private let hierarchy: HierarchyPersistence
    private let users: UserDirectoryPersistence

    init(
        serviceAccounts: ServiceAccountsPersistence,
        workloads: WorkloadsPersistence,
        projects: ProjectsPersistence,
        iam: IAMPersistence,
        groups: GroupsPersistence,
        hierarchy: HierarchyPersistence,
        users: UserDirectoryPersistence
    ) {
        self.serviceAccounts = serviceAccounts
        self.workloads = workloads
        self.projects = projects
        self.iam = iam
        self.groups = groups
        self.hierarchy = hierarchy
        self.users = users
    }
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

    struct CreateServiceAccountRequest: Content, ValidatedRequestBody {
        var name: String
        let description: String?

        mutating func validate() throws {
            name = try Validate.name(name)
            try Validate.text(description)
        }
    }

    struct UpdateServiceAccountRequest: Content, ValidatedRequestBody {
        let description: String?

        mutating func validate() throws {
            try Validate.text(description)
        }
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
        /// For a VM's instance-identity registration (STR-55), the VM it names.
        /// Nil on every agent and service-account row.
        let vmId: UUID?
        let displayName: String?
        let createdAt: Date?

        /// - Parameter displayName: overrides the stored label. VM-owned rows
        ///   store none and are hydrated from the VM's current name, so the
        ///   registry never shows a name a rename has already invalidated.
        init(_ row: WorkloadRegistrationSnapshot, displayName: String? = nil) throws {
            self.id = row.id
            self.spiffeId = row.spiffeID
            self.kind = row.kind
            self.agentName = row.agentName
            self.serviceAccountId = row.serviceAccountID
            self.organizationId = row.organizationID
            self.vmId = row.vmID
            self.displayName = displayName ?? row.displayName
            self.createdAt = row.createdAt
        }
    }

    struct CreateRegistrationRequest: Content {
        let spiffeId: String
    }

    // MARK: - CRUD

    /// GET /api/projects/:projectID/service-accounts
    func list(req: Request) async throws -> [ServiceAccountResponse] {
        let projectID = try await requireProjectID(req)
        try await req.authorize("serviceaccount:list", on: IAMNode(type: .project, id: projectID))

        let accounts = try await serviceAccounts.accounts(projectID: projectID)
        let rolesByAccount = try await projectRolesByAccount(
            accountIDs: accounts.map(\.id), projectID: projectID)
        return accounts.map { account in
            response(account, projectRoles: rolesByAccount[account.id] ?? [])
        }
    }

    /// POST /api/projects/:projectID/service-accounts
    func create(req: Request) async throws -> Response {
        let projectID = try await requireProjectID(req)
        try await req.authorize("serviceaccount:create", on: IAMNode(type: .project, id: projectID))

        let body = try req.content.decodeValidated(CreateServiceAccountRequest.self)
        let name = body.name

        let actorID = req.auth.get(User.self)?.id
        let account: ServiceAccountSnapshot
        do {
            account = try await serviceAccounts.create(
                ServiceAccountWrite(
                    name: name,
                    description: body.description ?? "",
                    projectID: projectID),
                creatorGrant: actorID.map {
                    ServiceAccountCreatorGrant(
                        principalID: $0,
                        roleID: IAMRole.admin.seededID,
                        createdBy: $0)
                })
        } catch ServiceAccountsPersistenceError.duplicateName {
            throw Abort(.conflict, reason: "A service account with this name already exists in the project")
        }

        let payload = response(account, projectRoles: [])
        let response = Response(status: .created)
        try response.content.encode(payload)
        return response
    }

    /// GET /api/service-accounts/:serviceAccountID
    func read(req: Request) async throws -> ServiceAccountResponse {
        let account = try await loadAccount(req)
        let accountID = account.id
        try await req.authorize("serviceaccount:read", on: IAMNode(type: .serviceAccount, id: accountID))
        let roles = try await projectRolesByAccount(
            accountIDs: [accountID], projectID: account.projectID)
        return response(account, projectRoles: roles[accountID] ?? [])
    }

    /// PATCH /api/service-accounts/:serviceAccountID
    func update(req: Request) async throws -> ServiceAccountResponse {
        let account = try await loadAccount(req)
        let accountID = account.id
        try await req.authorize("serviceaccount:update", on: IAMNode(type: .serviceAccount, id: accountID))

        let body = try req.content.decodeValidated(UpdateServiceAccountRequest.self)
        let updated: ServiceAccountSnapshot
        if let description = body.description {
            guard let replacement = try await serviceAccounts.replaceDescription(
                id: accountID, description: description)
            else { throw Abort(.notFound, reason: "Service account not found") }
            updated = replacement
        } else {
            updated = account
        }
        let roles = try await projectRolesByAccount(
            accountIDs: [accountID], projectID: account.projectID)
        return response(updated, projectRoles: roles[accountID] ?? [])
    }

    /// DELETE /api/service-accounts/:serviceAccountID
    func delete(req: Request) async throws -> HTTPStatus {
        let account = try await loadAccount(req)
        let accountID = account.id
        try await req.authorize("serviceaccount:delete", on: IAMNode(type: .serviceAccount, id: accountID))

        guard try await serviceAccounts.delete(id: accountID) else {
            throw Abort(.notFound, reason: "Service account not found")
        }
        return .noContent
    }

    // MARK: - Project role

    /// PUT /api/service-accounts/:serviceAccountID/project-role — grant the
    /// account a seeded role on its project, replacing any existing one. This
    /// is an IAM policy write on the project, gated and ceiling-reported
    /// exactly like user and group grants.
    func setProjectRole(req: Request) async throws -> Response {
        let account = try await loadAccount(req)
        let accountID = account.id
        let projectID = account.projectID
        try await req.authorize("iam:setPolicy", on: IAMNode(type: .project, id: projectID))

        let body = try req.content.decode(SetProjectRoleRequest.self)
        guard let role = IAMRole(rawValue: body.role) else {
            throw Abort(.badRequest, reason: "Invalid role; must be one of: viewer, operator, editor, admin")
        }

        // A ceiling in force on this project (or above it) may narrow what
        // this grant reaches — reported with the response (#484, STR-110).
        let proposed = ProposedBinding(
            principalType: .serviceAccount,
            principalID: accountID,
            role: role,
            node: IAMNode(type: .project, id: projectID)
        )

        let actorID = req.auth.get(User.self)?.id
        try await RoleBindingService.setExclusiveGrant(
            principalType: .serviceAccount,
            principalID: accountID,
            roleID: role.seededID,
            node: IAMNode(type: .project, id: projectID),
            createdBy: actorID,
            using: iam)
        return try await GuardrailWriteReport.report(
            for: proposed,
            using: iam,
            groups: groups,
            hierarchy: hierarchy,
            projects: projects,
            users: users,
            req: req)
            .encodeResponse(status: .ok, for: req)
    }

    /// DELETE /api/service-accounts/:serviceAccountID/project-role
    func clearProjectRole(req: Request) async throws -> HTTPStatus {
        let account = try await loadAccount(req)
        let accountID = account.id
        let projectID = account.projectID
        try await req.authorize("iam:setPolicy", on: IAMNode(type: .project, id: projectID))

        try await RoleBindingService.revoke(
            principalType: .serviceAccount,
            principalID: accountID,
            nodeType: .project,
            nodeID: projectID,
            using: iam
        )
        return .noContent
    }

    // MARK: - Workload registrations

    /// GET /api/service-accounts/:serviceAccountID/registrations
    func listRegistrations(req: Request) async throws -> [WorkloadRegistrationResponse] {
        let account = try await loadAccount(req)
        let accountID = account.id
        try await req.authorize("serviceaccount:read", on: IAMNode(type: .serviceAccount, id: accountID))

        return try await workloads.registrations(serviceAccountID: accountID)
            // No label hydration: a service account's registrations never carry
            // a `vm_id`, so there is no VM to read a current name from.
            .map { try WorkloadRegistrationResponse($0) }
    }

    /// POST /api/service-accounts/:serviceAccountID/registrations — register
    /// a SPIFFE identity as authenticating to this account. The identity is a
    /// lookup key only; nothing is ever parsed out of it.
    ///
    /// Gated on `iam:setPolicy` on the project, not `serviceaccount:update`:
    /// attaching an identity is what lets a workload act as the account and
    /// inherit everything it holds — grant-shaped power, so it sits behind
    /// the same admin-level gate as the account's role grants, out of
    /// editor reach.
    func createRegistration(req: Request) async throws -> Response {
        let account = try await loadAccount(req)
        let accountID = account.id
        try await req.authorize("iam:setPolicy", on: IAMNode(type: .project, id: account.projectID))

        let body = try req.content.decode(CreateRegistrationRequest.self)
        let spiffeID = try WorkloadRegistry.validateRegistrable(spiffeID: body.spiffeId)

        let registration: WorkloadRegistrationSnapshot
        do {
            registration = try await workloads.createRegistration(
                WorkloadRegistrationWrite(
                    spiffeID: spiffeID,
                    kind: WorkloadRegistrationKind.serviceAccount.rawValue,
                    serviceAccountID: accountID,
                    createdBy: req.auth.get(User.self)?.id))
        } catch WorkloadsPersistenceError.duplicateSPIFFEID {
            // One identity, one principal: the registry is a function.
            throw Abort(.conflict, reason: "This SPIFFE ID is already registered")
        }

        let response = Response(status: .created)
        try response.content.encode(try WorkloadRegistrationResponse(registration))
        return response
    }

    /// DELETE /api/service-accounts/:serviceAccountID/registrations/:registrationID
    /// — same grant-shaped gate as attaching one.
    func deleteRegistration(req: Request) async throws -> HTTPStatus {
        let account = try await loadAccount(req)
        let accountID = account.id
        try await req.authorize("iam:setPolicy", on: IAMNode(type: .project, id: account.projectID))

        guard let registrationID = req.parameters.get("registrationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid registration ID")
        }
        guard try await workloads.deleteRegistration(
            id: registrationID, serviceAccountID: accountID)
        else {
            throw Abort(.notFound, reason: "Registration not found")
        }
        return .noContent
    }

    // MARK: - Helpers

    private func response(
        _ account: ServiceAccountSnapshot, projectRoles: [String]
    ) -> ServiceAccountResponse {
        ServiceAccountResponse(
            id: account.id,
            name: account.name,
            description: account.description,
            projectId: account.projectID,
            projectRoles: projectRoles,
            createdAt: account.createdAt,
            updatedAt: account.updatedAt
        )
    }

    /// The seeded role names each account holds on the project, from its
    /// active bindings. Custom-role bindings are not representable in this
    /// summary and are omitted; the who-can API reports them.
    private func projectRolesByAccount(
        accountIDs: [UUID], projectID: UUID
    ) async throws -> [UUID: [String]] {
        guard !accountIDs.isEmpty else { return [:] }
        let bindings = try await iam.activeBindings(
            subjects: accountIDs.map {
                IAMOwnerReference(type: IAMPrincipalType.serviceAccount.rawValue, id: $0)
            },
            nodes: [IAMNodeReference(type: IAMNodeType.project.rawValue, id: projectID)])
        var roles: [UUID: [String]] = [:]
        for binding in bindings {
            guard let role = IAMRole(seededID: binding.roleID) else { continue }
            roles[binding.principalID, default: []].append(role.rawValue)
        }
        return roles.mapValues { $0.sorted() }
    }

    private func requireProjectID(_ req: Request) async throws -> UUID {
        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }
        guard try await projects.project(id: projectID) != nil else {
            throw Abort(.notFound, reason: "Project not found")
        }
        return projectID
    }

    private func loadAccount(_ req: Request) async throws -> ServiceAccountSnapshot {
        guard let accountID = req.parameters.get("serviceAccountID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid service account ID")
        }
        guard let account = try await serviceAccounts.account(id: accountID) else {
            throw Abort(.notFound, reason: "Service account not found")
        }
        return account
    }
}
