import Fluent
import Foundation
import Vapor

/// The workload registry surface (issue #491).
///
/// The registry inventory and direct workload registration are system-admin
/// platform plumbing, like the SPIRE inventory at `/api/workload-identity`:
/// registering an identity creates a *principal*, which is not itself a node
/// in the IAM tree. Granting such a principal a project role, by contrast, is
/// an ordinary IAM policy write on the project and is gated there.
struct WorkloadRegistrationController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let registrations = routes.grouped("api", "workload-registrations")
        registrations.get(use: list)
        registrations.post(use: create)
        registrations.delete(":registrationID", use: delete)

        let grants = routes.grouped("api", "projects", ":projectID", "workload-grants")
        grants.put(":registrationID", use: setGrant)
        grants.delete(":registrationID", use: clearGrant)
    }

    // MARK: - DTOs

    struct CreateWorkloadRegistrationRequest: Content {
        let spiffeId: String
        /// Administrative scoping for the registered workload. Grants
        /// nothing: machine principals hold access only via bindings.
        let organizationId: UUID
        let displayName: String?
    }

    struct SetWorkloadGrantRequest: Content {
        /// A seeded role name: viewer, operator, editor, or admin.
        let role: String
    }

    // MARK: - Registry (system admin)

    /// GET /api/workload-registrations — the full registry: agents, service
    /// accounts, and directly registered workloads.
    func list(req: Request) async throws -> [ServiceAccountController.WorkloadRegistrationResponse] {
        _ = try await req.requireSystemAdmin()
        return try await WorkloadRegistration.query(on: req.db)
            .sort(\.$spiffeID)
            .all()
            .map(ServiceAccountController.WorkloadRegistrationResponse.init)
    }

    /// POST /api/workload-registrations — register a customer workload's
    /// SPIFFE identity as a principal in its own right. The registration row
    /// *is* the principal (`principal_type = workload`, id = row id).
    func create(req: Request) async throws -> Response {
        let admin = try await req.requireSystemAdmin()
        let body = try req.content.decode(CreateWorkloadRegistrationRequest.self)

        // Same reserved-namespace rule as the service-account endpoint: even
        // an admin does not hand out /agent/ identities through the registry.
        let spiffeID = try WorkloadRegistry.validateRegistrable(spiffeID: body.spiffeId)
        guard try await Organization.find(body.organizationId, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Organization not found")
        }

        let registration = WorkloadRegistration(
            spiffeID: spiffeID,
            kind: .workload,
            organizationID: body.organizationId,
            displayName: body.displayName,
            createdBy: admin.id
        )
        do {
            try await registration.save(on: req.db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "This SPIFFE ID is already registered")
        }

        let response = Response(status: .created)
        try response.content.encode(try ServiceAccountController.WorkloadRegistrationResponse(registration))
        return response
    }

    /// DELETE /api/workload-registrations/:registrationID — the admin
    /// revocation lever, for any kind. Deleting a workload-kind row deletes
    /// the principal, so its bindings go with it (the offboarding rule).
    ///
    /// A VM's instance identity (STR-55) is deletable here on purpose, and this
    /// is the only revocation lever there is: refusing VM-owned rows would mean
    /// a compromised instance identity could not be revoked without deleting
    /// the VM, trading a recoverable operational mistake for an unrecoverable
    /// security one. It is a one-way door — identity is granted at VM create
    /// and there is no re-enable — so the removal is logged loudly rather than
    /// silently. Nothing re-creates the row on the next sync: a self-heal would
    /// undo the only revocation lever on a delay nobody can predict.
    func delete(req: Request) async throws -> HTTPStatus {
        _ = try await req.requireSystemAdmin()
        guard let registrationID = req.parameters.get("registrationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid registration ID")
        }
        guard let registration = try await WorkloadRegistration.find(registrationID, on: req.db) else {
            throw Abort(.notFound, reason: "Registration not found")
        }
        if let vmID = registration.$vm.id {
            req.logger.warning(
                "Revoking a VM's instance identity; it cannot be reissued for this VM",
                metadata: [
                    "vm_id": .string(vmID.uuidString),
                    "spiffe_id": .string(registration.spiffeID),
                ])
        }

        try await req.db.transaction { db in
            if registration.kind == .workload {
                try await RoleBindingService.revokeAll(
                    principalType: .workload, principalID: registrationID, on: db)
            }
            try await registration.delete(on: db)
        }
        return .noContent
    }

    // MARK: - Project grants

    /// PUT /api/projects/:projectID/workload-grants/:registrationID — grant a
    /// registered workload a seeded role on the project, replacing any
    /// existing one. Same gate and ceiling report as every other grant.
    func setGrant(req: Request) async throws -> Response {
        let (project, registration) = try await loadGrantTarget(req)
        let projectID = try project.requireID()
        let registrationID = try registration.requireID()
        try await req.authorize("iam:setPolicy", on: IAMNode(type: .project, id: projectID))

        let body = try req.content.decode(SetWorkloadGrantRequest.self)
        guard let role = IAMRole(rawValue: body.role) else {
            throw Abort(.badRequest, reason: "Invalid role; must be one of: viewer, operator, editor, admin")
        }

        // Keep grants within the registration's organization, the same rule
        // group grants follow.
        if let rootOrgID = try await project.getRootOrganizationId(on: req.db),
            registration.$organization.id != rootOrgID
        {
            throw Abort(.badRequest, reason: "Workload registration belongs to a different organization")
        }

        let proposed = ProposedBinding(
            principalType: .workload,
            principalID: registrationID,
            role: role,
            node: IAMNode(type: .project, id: projectID)
        )

        let actorID = req.auth.get(User.self)?.id
        try await req.db.transaction { db in
            try await RoleBindingService.revoke(
                principalType: .workload,
                principalID: registrationID,
                nodeType: .project,
                nodeID: projectID,
                on: db
            )
            try await RoleBindingService.grant(
                principalType: .workload,
                principalID: registrationID,
                role: role,
                nodeType: .project,
                nodeID: projectID,
                createdBy: actorID,
                on: db
            )
        }
        return try await GuardrailWriteReport.report(for: proposed, req: req)
            .encodeResponse(status: .ok, for: req)
    }

    /// DELETE /api/projects/:projectID/workload-grants/:registrationID
    func clearGrant(req: Request) async throws -> HTTPStatus {
        let (project, registration) = try await loadGrantTarget(req)
        let projectID = try project.requireID()
        let registrationID = try registration.requireID()
        try await req.authorize("iam:setPolicy", on: IAMNode(type: .project, id: projectID))

        try await RoleBindingService.revoke(
            principalType: .workload,
            principalID: registrationID,
            nodeType: .project,
            nodeID: projectID,
            on: req.db
        )
        return .noContent
    }

    private func loadGrantTarget(_ req: Request) async throws -> (Project, WorkloadRegistration) {
        let project = try await req.requireProject()
        guard let registrationID = req.parameters.get("registrationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid registration ID")
        }
        guard let registration = try await WorkloadRegistration.find(registrationID, on: req.db),
            registration.kind == .workload
        else {
            throw Abort(.notFound, reason: "Workload registration not found")
        }
        return (project, registration)
    }
}
