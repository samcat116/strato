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
        _ = try req.requireSystemAdmin()
        return try await WorkloadRegistration.query(on: req.db)
            .sort(\.$spiffeID)
            .all()
            .map(ServiceAccountController.WorkloadRegistrationResponse.init)
    }

    /// POST /api/workload-registrations — register a customer workload's
    /// SPIFFE identity as a principal in its own right. The registration row
    /// *is* the principal (`principal_type = workload`, id = row id).
    func create(req: Request) async throws -> Response {
        let admin = try req.requireSystemAdmin()
        let body = try req.content.decode(CreateWorkloadRegistrationRequest.self)

        guard SPIFFEIdentity(uri: body.spiffeId) != nil else {
            throw Abort(.badRequest, reason: "Not a valid SPIFFE URI (spiffe://<trust-domain>/<path>)")
        }
        guard try await Organization.find(body.organizationId, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Organization not found")
        }

        let registration = WorkloadRegistration(
            spiffeID: body.spiffeId,
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
    func delete(req: Request) async throws -> HTTPStatus {
        _ = try req.requireSystemAdmin()
        guard let registrationID = req.parameters.get("registrationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid registration ID")
        }
        guard let registration = try await WorkloadRegistration.find(registrationID, on: req.db) else {
            throw Abort(.notFound, reason: "Registration not found")
        }
        try await req.db.transaction { db in
            if registration.kind == .workload {
                for binding in try await RoleBindingService.activeBindings(
                    principalType: .workload, principalID: registrationID, on: db)
                {
                    try await binding.delete(on: db)
                }
            }
            try await registration.delete(on: db)
        }
        return .noContent
    }

    // MARK: - Project grants

    /// PUT /api/projects/:projectID/workload-grants/:registrationID — grant a
    /// registered workload a seeded role on the project, replacing any
    /// existing one. Same gate and guardrail check as every other grant.
    func setGrant(req: Request) async throws -> HTTPStatus {
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

        try await GuardrailWriteCheck.requireNoViolation(
            ProposedBinding(
                principalType: .workload,
                principalID: registrationID,
                role: role,
                node: IAMNode(type: .project, id: projectID)
            ), req: req)

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
        return .ok
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
        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }
        guard let project = try await Project.find(projectID, on: req.db) else {
            throw Abort(.notFound, reason: "Project not found")
        }
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
