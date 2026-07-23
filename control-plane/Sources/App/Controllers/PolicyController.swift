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
        _ = try requireUser(req)
        guard let ownerType = req.query[String.self, at: "ownerType"],
            let ownerId = req.query[String.self, at: "ownerId"]
        else {
            throw Abort(.badRequest, reason: "ownerType and ownerId query parameters are required")
        }
        let owner = try PolicyOwner(type: ownerType, id: ownerId)
        try await requirePolicyAdmin(on: owner.node, write: false, req: req)

        let policies = try await PolicyStore.owned(by: owner.type, ownerID: owner.id, on: req.db)
        return PolicyListResponse(policies: try policies.map(PolicyDTO.init))
    }

    /// GET /api/iam/policies/:policyID
    func get(req: Request) async throws -> PolicyDTO {
        _ = try requireUser(req)
        let policy = try await find(req)
        try await requirePolicyAdmin(on: try owner(of: policy).node, write: false, req: req)
        return try PolicyDTO(policy)
    }

    /// POST /api/iam/policies
    func create(req: Request) async throws -> Response {
        let user = try requireUser(req)
        let payload = try req.content.decode(CreatePolicyRequest.self)
        guard PolicyStore.creatableOwnerTypes.contains(payload.ownerType) else {
            throw PolicyError.uncreatableOwnerType(payload.ownerType.rawValue)
        }
        let owner = PolicyOwner(type: payload.ownerType, id: payload.ownerId)
        try await requireOwnerExists(owner, on: req.db)
        try await requirePolicyAdmin(on: owner.node, write: true, req: req)

        let id = payload.id ?? UUID()
        let prepared = try await PolicyStore.prepare(
            id: id, cedarText: payload.cedarText, ownerType: owner.type, ownerID: owner.id,
            engine: req.application.cedarEngine, on: req.db)

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

        let response = Response(status: .created)
        try response.content.encode(try PolicyDTO(policy))
        return response
    }

    /// PATCH /api/iam/policies/:policyID
    func update(req: Request) async throws -> PolicyDTO {
        let user = try requireUser(req)
        let existing = try await find(req)
        let owner = try owner(of: existing)
        try await requirePolicyAdmin(on: owner.node, write: true, req: req)
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

        return try PolicyDTO(updated)
    }

    /// DELETE /api/iam/policies/:policyID
    func delete(req: Request) async throws -> HTTPStatus {
        let user = try requireUser(req)
        let policy = try await find(req)
        try await requirePolicyAdmin(on: try owner(of: policy).node, write: true, req: req)
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
        _ = try requireUser(req)
        req.markRowScopedAuthorization()
        let payload = try req.content.decode(ValidatePolicyRequest.self)
        guard PolicyStore.creatableOwnerTypes.contains(payload.ownerType) else {
            throw PolicyError.uncreatableOwnerType(payload.ownerType.rawValue)
        }
        let id = payload.id ?? UUID()
        let prepared = try await PolicyStore.prepare(
            id: id, cedarText: payload.cedarText, ownerType: payload.ownerType, ownerID: payload.ownerId,
            engine: req.application.cedarEngine, on: req.db)
        return ValidatePolicyResponse(id: id, cedarText: prepared.cedarText, effect: prepared.effect)
    }

    // MARK: - Helpers

    /// A policy's owner as both halves it is used as: the store's
    /// `(ownerType, ownerID)` pair and the tree node the gates run on.
    private struct PolicyOwner {
        let type: IAMRoleOwnerType
        let id: UUID

        var node: IAMNode {
            // Every creatable owner type has a node type; the platform sentinel
            // is not a creatable policy owner and is refused before this.
            IAMNode(type: type.nodeType ?? .organization, id: id)
        }

        init(type: IAMRoleOwnerType, id: UUID) {
            self.type = type
            self.id = id
        }

        init(type: String, id: String) throws {
            guard let ownerType = IAMRoleOwnerType(rawValue: type),
                PolicyStore.creatableOwnerTypes.contains(ownerType)
            else {
                throw PolicyError.uncreatableOwnerType(type)
            }
            guard let ownerID = UUID(uuidString: id) else {
                throw Abort(.badRequest, reason: "Policy owner id must be a UUID")
            }
            self.init(type: ownerType, id: ownerID)
        }
    }

    private func requireUser(_ req: Request) throws -> User {
        guard let user = req.auth.get(User.self) else { throw Abort(.unauthorized) }
        return user
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

    private func owner(of policy: IAMPolicy) throws -> PolicyOwner {
        guard let type = policy.owner else {
            throw Abort(.internalServerError, reason: "Policy row names an unknown owner type '\(policy.ownerType)'")
        }
        return PolicyOwner(type: type, id: policy.ownerID)
    }

    /// A policy scoped to an owner that does not exist would be attributable
    /// nowhere, so this is a `404` at the boundary rather than an orphan row.
    private func requireOwnerExists(_ owner: PolicyOwner, on db: any Database) async throws {
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
            throw PolicyError.unknownOwner("\(owner.type.rawValue)/\(owner.id)")
        }
    }

    /// Reading and writing a policy is `iam:readPolicy` / `iam:setPolicy` on
    /// its owner — the same gate roles and guardrails use.
    private func requirePolicyAdmin(on node: IAMNode, write: Bool, req: Request) async throws {
        guard try await req.can(write ? "iam:setPolicy" : "iam:readPolicy", on: node) else {
            throw Abort(
                .forbidden, reason: "Managing policies requires admin on the policy's owner or a container above it")
        }
    }
}
