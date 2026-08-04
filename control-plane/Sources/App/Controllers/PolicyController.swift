import Fluent
import Vapor

/// The authored-policy API (issue #606): creating and editing permit/forbid
/// policies written directly in Cedar, owned by an org or project.
///
/// Same posture as roles and guardrails — a policy is policy, not data. Every
/// write is `iam:setPolicy` on the policy's owner, runs inside
/// `withPolicySetChange` so the row and its version bump commit together, and
/// announces the change so every replica recompiles. Reading a policy is
/// `iam:readPolicy`: what a policy permits or forbids is a statement about who
/// can do what.
struct PolicyController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let iam = routes.grouped("api", "iam")

        let policies = iam.grouped("policies")
        policies.get(use: list)
        policies.post(use: create)
        // Static segment before the parameter: Vapor prefers the literal, so
        // this is never read as a policy id.
        policies.post("validate", use: validate)
        policies.group(":policyID") { policy in
            policy.get(use: get)
            policy.patch(use: update)
            policy.delete(use: delete)
        }
    }

    // MARK: - DTOs

    struct PolicyDTO: Content {
        let id: UUID
        let name: String
        let description: String?
        let ownerType: IAMRoleOwnerType
        let ownerId: UUID
        /// The policy's Cedar text. Round-trips: what comes back here is
        /// accepted verbatim as `cedarText` on a later write.
        let cedarText: String
        /// `permit` or `forbid`, derived from `cedarText` and never sent by the
        /// client.
        let effect: IAMPolicyEffect
        let enabled: Bool
        let createdBy: UUID?
        let createdAt: Date?
        let updatedAt: Date?

        init(_ policy: IAMPolicy) throws {
            guard let id = policy.id,
                let ownerType = policy.owner,
                let effect = policy.policyEffect
            else {
                throw Abort(
                    .internalServerError,
                    reason: "Policy row is missing its id or names an unknown owner type or effect")
            }
            self.id = id
            self.name = policy.name
            self.description = policy.description
            self.ownerType = ownerType
            self.ownerId = policy.ownerID
            self.cedarText = policy.cedarText
            self.effect = effect
            self.enabled = policy.enabled
            self.createdBy = policy.createdBy
            self.createdAt = policy.createdAt
            self.updatedAt = policy.updatedAt
        }
    }

    struct CreatePolicyRequest: Content {
        let name: String
        let description: String?
        let ownerType: IAMRoleOwnerType
        let ownerId: UUID
        /// The Cedar permit or forbid. The effect is read off it; there is no
        /// action-list shorthand — an authored policy is Cedar by definition.
        let cedarText: String
        let enabled: Bool?
        /// Optional pre-allocated id (a `validate` round-trip hands one out).
        /// Nothing in the policy text references the id, so the server can
        /// allocate it just as well.
        let id: UUID?
    }

    struct UpdatePolicyRequest: Content {
        let name: String?
        let description: String?
        let cedarText: String?
        let enabled: Bool?
    }

    /// `POST /api/iam/policies/validate` — compile and containment-check
    /// without saving.
    struct ValidatePolicyRequest: Content {
        let ownerType: IAMRoleOwnerType
        let ownerId: UUID
        let cedarText: String
        /// The policy being edited, so the id its compiled form uses is stable.
        /// Omitted for a policy that does not exist yet.
        let id: UUID?
    }

    struct ValidatePolicyResponse: Content {
        let id: UUID
        let cedarText: String
        let effect: IAMPolicyEffect
    }

    struct PolicyListResponse: Content {
        let policies: [PolicyDTO]
    }

    // MARK: - Routes

    /// GET /api/iam/policies?ownerType=&ownerId=
    func list(req: Request) async throws -> PolicyListResponse {
        _ = try req.requireUser()
        guard let ownerType = req.query[String.self, at: "ownerType"],
            let ownerId = req.query[String.self, at: "ownerId"]
        else {
            throw Abort(.badRequest, reason: "ownerType and ownerId query parameters are required")
        }
        let owner = try IAMPolicySetOwner(type: ownerType, id: ownerId, kind: .policy)
        try await owner.requirePolicyAdmin(write: false, req: req)

        let policies = try await PolicyStore.owned(by: owner.type, ownerID: owner.id, on: req.db)
        return PolicyListResponse(policies: try policies.map(PolicyDTO.init))
    }

    /// GET /api/iam/policies/:policyID
    func get(req: Request) async throws -> PolicyDTO {
        _ = try req.requireUser()
        let policy = try await find(req)
        try await owner(of: policy).requirePolicyAdmin(write: false, req: req)
        return try PolicyDTO(policy)
    }

    /// POST /api/iam/policies
    func create(req: Request) async throws -> Response {
        let user = try req.requireUser()
        let payload = try req.content.decode(CreatePolicyRequest.self)
        let owner = try IAMPolicySetOwner(creating: payload.ownerType, id: payload.ownerId, kind: .policy)
        try await owner.requireExists(on: req.db)
        try await owner.requirePolicyAdmin(write: true, req: req)

        let id = payload.id ?? UUID()
        let prepared = try await PolicyStore.prepare(
            id: id, cedarText: payload.cedarText, ownerType: owner.type, ownerID: owner.id,
            engine: req.application.cedarEngine, on: req.db)
        let crossOrgGrant = try await requireAuthoredGrantPermitted(prepared, owner: owner, req: req)

        let policy = try await PolicySetVersionService.withPolicySetChange(on: req.db) { db in
            let policy = try await PolicyStore.create(
                id: id,
                name: payload.name,
                description: payload.description,
                ownerType: owner.type,
                ownerID: owner.id,
                prepared: prepared,
                createdBy: user.id,
                enabled: payload.enabled ?? true,
                on: db
            )
            try await PolicySetVersionService.bump(
                reason: "policy created: \(payload.name)", changedBy: user.id, on: db)
            return policy
        }
        await req.application.announcePolicySetChange()
        if let crossOrgGrant {
            await recordAuthoredCrossOrgGrant(policyID: id, owner: owner, grant: crossOrgGrant, req: req)
        }

        let response = Response(status: .created)
        try response.content.encode(try PolicyDTO(policy))
        return response
    }

    /// PATCH /api/iam/policies/:policyID
    func update(req: Request) async throws -> PolicyDTO {
        let user = try req.requireUser()
        let existing = try await find(req)
        let owner = try owner(of: existing)
        try await owner.requirePolicyAdmin(write: true, req: req)
        guard let id = existing.id else {
            throw Abort(.internalServerError, reason: "Policy row is missing its id")
        }

        let payload = try req.content.decode(UpdatePolicyRequest.self)
        // Re-preparing only when the text changes: containment and the Cedar
        // compile are about the text, and a labels- or enabled-only edit does
        // not touch it.
        let prepared: PolicyStore.Prepared? =
            payload.cedarText != nil
            ? try await PolicyStore.prepare(
                id: id, cedarText: payload.cedarText!, ownerType: owner.type, ownerID: owner.id,
                engine: req.application.cedarEngine, on: req.db)
            : nil
        var crossOrgGrant: AuthoredCrossOrgGrant?
        if let prepared {
            crossOrgGrant = try await requireAuthoredGrantPermitted(prepared, owner: owner, req: req)
        }

        let name = payload.name ?? existing.name
        let updated = try await PolicySetVersionService.withPolicySetChange(on: req.db) { db in
            // Re-read inside the transaction so the edit and the bump see the
            // same row, and a retried attempt starts from the row as it is now.
            guard let policy = try await IAMPolicy.find(id, on: db) else {
                throw Abort(.notFound, reason: "Policy not found")
            }
            if let newName = payload.name { policy.name = newName }
            if let description = payload.description { policy.description = description }
            if let prepared {
                policy.cedarText = prepared.cedarText
                policy.effect = prepared.effect.rawValue
            }
            if let enabled = payload.enabled { policy.enabled = enabled }
            do {
                try await policy.save(on: db)
            } catch let error as any DatabaseError where error.isConstraintFailure {
                throw PolicyError.duplicateName(name)
            }
            try await PolicySetVersionService.bump(
                reason: "policy updated: \(name)", changedBy: user.id, on: db)
            return policy
        }
        await req.application.announcePolicySetChange()
        if let crossOrgGrant {
            await recordAuthoredCrossOrgGrant(
                policyID: id, owner: owner, grant: crossOrgGrant, req: req)
        }

        return try PolicyDTO(updated)
    }

    /// DELETE /api/iam/policies/:policyID
    func delete(req: Request) async throws -> HTTPStatus {
        let user = try req.requireUser()
        let policy = try await find(req)
        try await owner(of: policy).requirePolicyAdmin(write: true, req: req)
        guard let id = policy.id else {
            throw Abort(.internalServerError, reason: "Policy row is missing its id")
        }

        let name = policy.name
        try await PolicySetVersionService.withPolicySetChange(on: req.db) { db in
            try await IAMPolicy.query(on: db).filter(\.$id == id).delete()
            try await PolicySetVersionService.bump(
                reason: "policy deleted: \(name)", changedBy: user.id, on: db)
        }
        await req.application.announcePolicySetChange()

        return .noContent
    }

    /// POST /api/iam/policies/validate
    ///
    /// The editor's compile button: the same preparation a write does —
    /// effect derivation, containment, and a real Cedar compile — minus the
    /// write. Authenticated but not admin-gated, matching the role editor's
    /// `validate`: it stores nothing, and the schema it compiles against is
    /// what the deployment already publishes. Declared row-scoped so the
    /// default-deny middleware does not read a POST that evaluates nothing as a
    /// handler that forgot its check.
    func validate(req: Request) async throws -> ValidatePolicyResponse {
        _ = try req.requireUser()
        req.markRowScopedAuthorization()
        let payload = try req.content.decode(ValidatePolicyRequest.self)
        // Containment is checked against the owner the editor is writing for,
        // so `validate` refuses an owner type a create would refuse too.
        let owner = try IAMPolicySetOwner(creating: payload.ownerType, id: payload.ownerId, kind: .policy)
        let id = payload.id ?? UUID()
        let prepared = try await PolicyStore.prepare(
            id: id, cedarText: payload.cedarText, ownerType: owner.type, ownerID: owner.id,
            engine: req.application.cedarEngine, on: req.db)
        return ValidatePolicyResponse(id: id, cedarText: prepared.cedarText, effect: prepared.effect)
    }

    // MARK: - Helpers

    /// A cross-org grant made by authoring a `permit` policy, carried from the
    /// write-time gate to the post-commit audit. The principal is present only
    /// when the policy named a single one; an unconstrained/bare-type permit
    /// grants to many, so there is no single principal to record.
    private struct AuthoredCrossOrgGrant {
        let principalType: IAMPrincipalType?
        let principalID: UUID?
    }

    /// The authored-policy analogue of `CrossOrgBindingGate.requireGrantPermitted`.
    ///
    /// A `permit` whose principal reaches outside the owner's organization
    /// grants external access, so authoring it must pass `iam:grantExternal` on
    /// the owner — the same distinct, separately-withholdable permission the
    /// binding path uses — rather than riding `iam:setPolicy` alone. Without
    /// this, a delegated policy-admin given `iam:setPolicy` but deliberately not
    /// `iam:grantExternal` (or ceilinged by a guardrail on it) could grant
    /// arbitrary external principals access to their subtree, bypassing the
    /// named control and its `crossOrgGrant` audit. Returns the grant to audit
    /// when the write commits, or nil when no cross-org grant is authored.
    private func requireAuthoredGrantPermitted(
        _ prepared: PolicyStore.Prepared, owner: IAMPolicySetOwner, req: Request
    ) async throws -> AuthoredCrossOrgGrant? {
        // A forbid grants nothing; only a permit can reach an external principal.
        guard prepared.effect == .permit else { return nil }
        let ownerNode = owner.node

        // Resolve a single, named principal (`== E` / `in E`) to a typed one.
        var namedPrincipal: (type: IAMPrincipalType, id: UUID)?
        if prepared.principalConstrained, let scope = prepared.principalScope,
            let type = scope.type.iamPrincipalType
        {
            namedPrincipal = (type, scope.id)
        }

        // A named principal internal to the owner's org is an ordinary in-org
        // grant and needs no cross-org permission.
        if let principal = namedPrincipal {
            let external = try await CrossOrgBindingGate.isCrossOrg(
                principalType: principal.type, principalID: principal.id, node: ownerNode, on: req.db)
            if !external { return nil }
        }

        // Everything else a permit can reach — the unconstrained `principal`, a
        // bare `principal is T`, an `in <group>`/reference not resolved to one
        // entity, or a named *external* principal — grants access outside the
        // org. Require `iam:grantExternal` on the owner, so a role that withholds
        // it or a guardrail that ceilings it can't be sidestepped via a policy.
        guard try await req.can("iam:grantExternal", on: ownerNode) else {
            throw Abort(
                .forbidden,
                reason:
                    "This policy grants access to principals outside its organization; authoring it requires the iam:grantExternal permission on the owner"
            )
        }
        return AuthoredCrossOrgGrant(principalType: namedPrincipal?.type, principalID: namedPrincipal?.id)
    }

    /// Loud audit for a cross-org grant authored as a policy, mirroring
    /// `CrossOrgBindingGate.recordCrossOrgEvent`. Best-effort — never fails the
    /// request.
    private func recordAuthoredCrossOrgGrant(
        policyID: UUID, owner: IAMPolicySetOwner, grant: AuthoredCrossOrgGrant, req: Request
    ) async {
        let actor = req.auth.get(User.self)
        var metadata: [String: String] = [
            "via": "authored_policy",
            "policyId": policyID.uuidString,
        ]
        if let type = grant.principalType { metadata["principalType"] = type.rawValue }
        if let id = grant.principalID { metadata["principalId"] = id.uuidString }
        await req.audit.record(
            AuditRecord(
                eventType: AuditEventType.crossOrgGrant.rawValue,
                userID: actor?.id,
                username: actor?.username,
                apiKeyID: req.apiKey?.id,
                organizationID: try? await CrossOrgBindingGate.rootOrganizationID(
                    of: owner.node, on: req.db),
                method: req.method.rawValue,
                path: req.url.path,
                resourceType: owner.node.type.rawValue,
                resourceID: owner.node.id.uuidString,
                action: "iam:grantExternal",
                sourceIP: req.auditClientIP,
                metadata: metadata
            ))
    }

    private func find(_ req: Request) async throws -> IAMPolicy {
        guard let id = req.parameters.get("policyID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Policy id must be a UUID")
        }
        guard let policy = try await IAMPolicy.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Policy not found")
        }
        return policy
    }

    private func owner(of policy: IAMPolicy) throws -> IAMPolicySetOwner {
        guard let type = policy.owner else {
            throw Abort(.internalServerError, reason: "Policy row names an unknown owner type '\(policy.ownerType)'")
        }
        return IAMPolicySetOwner(type: type, id: policy.ownerID, kind: .policy)
    }
}

extension CedarEntityType {
    /// The IAM principal type this entity type denotes, or nil for a resource
    /// type. Used to decide whether a policy's named principal is a subject
    /// that can be internal/external to an organization.
    fileprivate var iamPrincipalType: IAMPrincipalType? {
        switch self {
        case .user: return .user
        case .group: return .group
        case .serviceAccount: return .serviceAccount
        case .workload: return .workload
        default: return nil
        }
    }
}
