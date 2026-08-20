import Foundation
import ControlPlanePostgres
import Fluent
import Vapor

/// The workload registry surface (issue #491).
///
/// The registry inventory and direct workload registration are system-admin
/// platform plumbing, like the SPIRE inventory at `/api/workload-identity`:
/// registering an identity creates a *principal*, which is not itself a node
/// in the IAM tree. Granting such a principal a project role, by contrast, is
/// an ordinary IAM policy write on the project and is gated there.
struct WorkloadRegistrationController: RouteCollection {
    private let workloads: WorkloadsPersistence

    init(workloads: WorkloadsPersistence) {
        self.workloads = workloads
    }

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

    struct CreateWorkloadRegistrationRequest: Content, ValidatedRequestBody {
        let spiffeId: String
        /// Administrative scoping for the registered workload. Grants
        /// nothing: machine principals hold access only via bindings.
        let organizationId: UUID
        var displayName: String?

        mutating func validate() throws {
            displayName = try Validate.name(displayName, "displayName")
        }
    }

    struct SetWorkloadGrantRequest: Content {
        /// A canonical role UUID. Seeded role names remain accepted for API
        /// compatibility with the original workload-grant surface.
        let role: String
    }

    // MARK: - Registry (system admin)

    /// GET /api/workload-registrations — the registry: agents, service
    /// accounts, and directly registered workloads (including every VM's
    /// instance identity).
    ///
    /// Paged and filterable, which it was not before STR-55 made it
    /// fleet-sized. Both of this feature's remediation paths — the `409` a
    /// create answers when a constraint could not be satisfied, and the
    /// backfill's stranded-VM warning — send an operator here to look for a
    /// squatted SPIFFE ID, so an unbounded listing of one row per VM would make
    /// the diagnostics unusable exactly when they are needed. `spiffeId` turns
    /// that lookup into an exact match; `kind` and `vmOwned` narrow the
    /// inventory view.
    func list(req: Request) async throws -> PagedResponse<
        ServiceAccountController.WorkloadRegistrationResponse
    > {
        _ = try await req.requireSystemAdmin()
        let paging = try ListPaging.decode(from: req)

        var kind: String?
        if let rawKind = req.query[String.self, at: "kind"] {
            guard WorkloadRegistrationKind(rawValue: rawKind) != nil else {
                throw Abort(
                    .badRequest,
                    reason:
                        "Invalid kind; must be one of: \(WorkloadRegistrationKind.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            kind = rawKind
        }
        // Exact match, not a prefix search: a SPIFFE ID is a lookup key, and
        // the operator diagnosing a squat has the whole URI in hand.
        let spiffeID = req.query[String.self, at: "spiffeId"]
        // `boolQuery`, not `query[Bool.self, at:]`: the latter reads a missing
        // key as `false`, which would make an unfiltered listing quietly exclude
        // every VM's identity — the majority of the table.
        let vmOwned = try req.boolQuery("vmOwned")

        let rows = try await workloads.registrations(
            kind: kind, spiffeID: spiffeID, vmOwned: vmOwned)
        // Only the requested page's labels are hydrated, so the extra query is
        // bounded by `limit` rather than by the fleet.
        let pageItems: [WorkloadRegistrationSnapshot]
        if paging.offset < rows.count {
            pageItems = Array(
                rows[paging.offset..<min(paging.offset + paging.limit, rows.count)])
        } else {
            pageItems = []
        }
        let names = try await GuestIdentity.names(
            forVMs: pageItems.compactMap(\.vmID), on: req.db)

        return PagedResponse(
            items: try pageItems.map {
                try ServiceAccountController.WorkloadRegistrationResponse(
                    $0, displayName: $0.vmID.flatMap { id in names[id] })
            },
            total: rows.count,
            limit: paging.limit,
            offset: paging.offset
        )
    }

    /// POST /api/workload-registrations — register a customer workload's
    /// SPIFFE identity as a principal in its own right. The registration row
    /// *is* the principal (`principal_type = workload`, id = row id).
    func create(req: Request) async throws -> Response {
        let admin = try await req.requireSystemAdmin()
        let body = try req.content.decodeValidated(CreateWorkloadRegistrationRequest.self)

        // Same reserved-namespace rule as the service-account endpoint: even
        // an admin does not hand out platform-owned identities through the registry.
        let spiffeID = try WorkloadRegistry.validateRegistrable(spiffeID: body.spiffeId)
        guard try await Organization.find(body.organizationId, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Organization not found")
        }

        let registration: WorkloadRegistrationSnapshot
        do {
            registration = try await workloads.createRegistration(
                WorkloadRegistrationWrite(
                    spiffeID: spiffeID,
                    kind: WorkloadRegistrationKind.workload.rawValue,
                    organizationID: body.organizationId,
                    displayName: body.displayName,
                    createdBy: admin.id))
        } catch WorkloadsPersistenceError.duplicateSPIFFEID {
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
        guard let registration = try await workloads.registration(id: registrationID) else {
            throw Abort(.notFound, reason: "Registration not found")
        }
        if let vmID = registration.vmID {
            req.logger.warning(
                "Revoking a VM's instance identity; it cannot be reissued for this VM",
                metadata: [
                    "vm_id": .string(vmID.uuidString),
                    "spiffe_id": .string(registration.spiffeID),
                ])
        }

        try await req.db.transaction { db in
            if registration.kind == WorkloadRegistrationKind.workload.rawValue {
                try await RoleBindingService.revokeAll(
                    principalType: .workload, principalID: registrationID, on: db)
            }
            try await LegacyWorkloadRegistrationStore.delete(id: registrationID, on: db)
        }
        return .noContent
    }

    // MARK: - Project grants

    /// PUT /api/projects/:projectID/workload-grants/:registrationID — grant a
    /// registered workload a bindable role on the project, replacing any
    /// existing one. Same gate and ceiling report as every other grant.
    func setGrant(req: Request) async throws -> Response {
        let (project, registration) = try await loadGrantTarget(req)
        let projectID = try project.requireID()
        let registrationID = registration.id
        try await req.authorize("iam:setPolicy", on: IAMNode(type: .project, id: projectID))

        let body = try req.content.decode(SetWorkloadGrantRequest.self)
        let roleID: UUID
        if let id = UUID(uuidString: body.role) {
            roleID = id
        } else if let seeded = IAMRole(rawValue: body.role) {
            roleID = seeded.seededID
        } else {
            throw Abort(
                .badRequest,
                reason: "Invalid role; use a role id returned by /api/iam/roles/bindable")
        }
        let node = IAMNode(type: .project, id: projectID)
        let role = try await MemberRoleResolver.resolve(roleID, scopeNode: node, on: req.db)

        // Keep grants within the registration's organization, the same rule
        // group grants follow.
        if let rootOrgID = try await project.getRootOrganizationId(on: req.db),
            registration.organizationID != rootOrgID
        {
            throw Abort(.badRequest, reason: "Workload registration belongs to a different organization")
        }

        let proposed = ProposedBinding(
            principalType: .workload,
            principalID: registrationID,
            roleActions: role.actions,
            roleLabel: role.displayName,
            node: node
        )

        let actorID = req.auth.get(User.self)?.id
        try await RoleBindingService.setExclusiveGrant(
            principalType: .workload, principalID: registrationID,
            roleID: role.id, node: node, createdBy: actorID, on: req.db)
        return try await GuardrailWriteReport.report(for: proposed, req: req)
            .encodeResponse(status: .ok, for: req)
    }

    /// DELETE /api/projects/:projectID/workload-grants/:registrationID
    func clearGrant(req: Request) async throws -> HTTPStatus {
        let (project, registration) = try await loadGrantTarget(req)
        let projectID = try project.requireID()
        let registrationID = registration.id
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

    private func loadGrantTarget(
        _ req: Request
    ) async throws -> (Project, WorkloadRegistrationSnapshot) {
        let project = try await req.requireProject()
        guard let registrationID = req.parameters.get("registrationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid registration ID")
        }
        guard let registration = try await workloads.registration(id: registrationID),
            registration.kind == WorkloadRegistrationKind.workload.rawValue
        else {
            throw Abort(.notFound, reason: "Workload registration not found")
        }
        return (project, registration)
    }
}
