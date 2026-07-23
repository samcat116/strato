import Fluent
import Vapor

/// The tier-2 guardrail API (issue #479): ceilings on what grants beneath a
/// node can reach, plus the policy-set version they live under.
///
/// Every route is admin-gated on the node the guardrail attaches to — writing
/// a ceiling is `iam:setPolicy`-shaped, and reading one tells you how the
/// subtree is constrained.
struct GuardrailController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let iam = routes.grouped("api", "iam")

        let guardrails = iam.grouped("guardrails")
        guardrails.get(use: list)
        guardrails.post(use: create)
        guardrails.group(":guardrailID") { guardrail in
            guardrail.get(use: get)
            guardrail.patch(use: update)
            guardrail.delete(use: delete)
        }

        iam.get("policy-set", "version", use: policySetVersion)
    }

    // MARK: - DTOs

    /// The principal side of a guardrail, on the wire.
    struct PrincipalMatchDTO: Content {
        let kind: GuardrailPrincipalMatchKind
        /// The user or group id, for `user` / `group`.
        let id: UUID?

        func toMatch() throws -> GuardrailPrincipalMatch {
            try GuardrailPrincipalMatch.from(kind: kind, subjectID: id)
        }

        static func from(_ match: GuardrailPrincipalMatch) -> PrincipalMatchDTO {
            PrincipalMatchDTO(kind: match.kind, id: match.subjectID)
        }
    }

    /// The resource side of a guardrail, on the wire.
    struct ResourceMatchDTO: Content {
        let kind: GuardrailResourceMatchKind
        /// The environment name, for `environment`.
        let value: String?

        func toMatch() throws -> GuardrailResourceMatch {
            try GuardrailResourceMatch.from(kind: kind, value: value)
        }

        static func from(_ match: GuardrailResourceMatch) -> ResourceMatchDTO {
            ResourceMatchDTO(kind: match.kind, value: match.value)
        }
    }

    struct GuardrailDTO: Content {
        let id: UUID
        let name: String
        let description: String?
        let node: IAMNode
        /// Always `forbid`. Present so the response states the invariant rather
        /// than leaving the reader to infer it.
        let effect: String
        let actions: [String]
        let principalMatch: PrincipalMatchDTO
        let resourceMatch: ResourceMatchDTO
        /// Which side carries the constraint — derived, see `Guardrail.shape`.
        let shape: String
        /// The Cedar `forbid` this guardrail compiles to (issue #606, stored as
        /// the source of truth since #610). For a matcher-built row it is
        /// generated from the matchers; for an authored row it is what the admin
        /// wrote. Nil only for a row that cannot be rendered (an unknown node
        /// type, or an external-principal ceiling whose attach node resolves to
        /// no organization) — the same rows the compiled set skips.
        let cedarText: String?
        /// Whether the forbid was hand-authored (`true`) or assembled from the
        /// matchers (`false`, #610). On an authored row the matcher fields above
        /// are placeholders; a builder UI reads this to decide which editor to
        /// show.
        let authored: Bool
        let enabled: Bool
        let createdBy: UUID?
        let createdAt: Date?
        let updatedAt: Date?

        init(_ guardrail: Guardrail, cedarText: String?) throws {
            guard let id = guardrail.id, let node = guardrail.node else {
                throw Abort(.internalServerError, reason: "Guardrail row is missing its id or node")
            }
            self.id = id
            self.name = guardrail.name
            self.description = guardrail.description
            self.node = node
            self.effect = guardrail.effect
            self.actions = guardrail.actions
            self.principalMatch = PrincipalMatchDTO.from(try guardrail.principalMatch())
            self.resourceMatch = ResourceMatchDTO.from(try guardrail.resourceMatch())
            self.shape = guardrail.shape
            self.cedarText = cedarText
            self.authored = guardrail.authored
            self.enabled = guardrail.enabled
            self.createdBy = guardrail.createdBy
            self.createdAt = guardrail.createdAt
            self.updatedAt = guardrail.updatedAt
        }
    }

    struct CreateGuardrailRequest: Content {
        let name: String
        let description: String?
        /// Optional, and only ever `forbid`. A request naming anything else is
        /// rejected rather than silently coerced.
        let effect: String?
        let nodeType: String
        let nodeId: String
        /// Exact actions, `service:*`, or `*`. Empty means every action.
        let actions: [String]?
        let principalMatch: PrincipalMatchDTO?
        let resourceMatch: ResourceMatchDTO?
        /// Advanced (#610): a hand-written Cedar `forbid`, held to the guardrail
        /// shape (forbid-only, contained to the attach node, not self-locking).
        /// Sent *instead of* the matchers, not alongside — the two together are
        /// a `400`.
        let cedarText: String?
        let enabled: Bool?
    }

    struct UpdateGuardrailRequest: Content {
        let description: String?
        let actions: [String]?
        let principalMatch: PrincipalMatchDTO?
        let resourceMatch: ResourceMatchDTO?
        /// Advanced (#610): edit an authored guardrail's Cedar text. Rejected on
        /// a matcher-built guardrail — edit its matchers instead.
        let cedarText: String?
        let enabled: Bool?
    }

    /// A guardrail write's response: the row, plus the grants it just
    /// narrowed.
    ///
    /// The write is never refused over these — subtracting from existing
    /// grants is a ceiling's job, and one that could not be imposed until
    /// every grant beneath it had been cleaned up first would be useless
    /// during the incident it was written for. Reporting them is so the author
    /// finds out now rather than from whoever loses access (#484).
    struct GuardrailWriteResponse: Content {
        let guardrail: GuardrailDTO
        let shadowedBindings: [GuardrailWriteCheck.ShadowedBinding]
    }

    struct GuardrailListResponse: Content {
        let node: IAMNode
        /// When the request asked for the effective set, the chain the answer
        /// was assembled from — resource first — so an inherited ceiling is
        /// explicable without a second round trip.
        let ancestors: [IAMNode]?
        let guardrails: [GuardrailDTO]
    }

    struct PolicySetVersionResponse: Content {
        /// The version in the database — what a write would build on.
        let version: Int
        /// The version *this replica* has observed. A lag between the two is
        /// normal for a moment after a change and self-corrects; a persistent
        /// one means this replica is missing invalidations.
        let replicaVersion: Int
        let latest: PolicySetVersion?
    }

    // MARK: - Routes

    /// GET /api/iam/guardrails?nodeType=&nodeId=[&effective=true]
    ///
    /// By default, the guardrails attached to the node. With `effective=true`,
    /// every enabled guardrail in force there — the node's own plus everything
    /// inherited from above. They intersect; the effective set is the whole
    /// list, not the nearest entry.
    func list(req: Request) async throws -> GuardrailListResponse {
        _ = try requireUser(req)
        guard let nodeType = req.query[String.self, at: "nodeType"],
            let nodeId = req.query[String.self, at: "nodeId"]
        else {
            throw Abort(.badRequest, reason: "nodeType and nodeId query parameters are required")
        }
        let node = try IAMPolicyGate.node(resourceType: nodeType, resourceId: nodeId)
        try await requirePolicyAdmin(on: node, write: false, req: req)

        let effective = req.query[Bool.self, at: "effective"] ?? false
        if effective {
            let ancestors = try await IAMResourceTree.ancestors(of: node, on: req.db)
            let guardrails = try await GuardrailStore.effective(along: ancestors, on: req.db)
            return GuardrailListResponse(
                node: node,
                ancestors: ancestors,
                guardrails: try await dtos(guardrails, on: req.db)
            )
        }

        let guardrails = try await GuardrailStore.attached(to: node, on: req.db)
        return GuardrailListResponse(
            node: node, ancestors: nil, guardrails: try await dtos(guardrails, on: req.db))
    }

    /// GET /api/iam/guardrails/:guardrailID
    func get(req: Request) async throws -> GuardrailDTO {
        _ = try requireUser(req)
        let guardrail = try await find(req)
        try await requirePolicyAdmin(on: try nodeOf(guardrail), write: false, req: req)
        return try await dto(guardrail, on: req.db)
    }

    /// POST /api/iam/guardrails
    func create(req: Request) async throws -> Response {
        let user = try requireUser(req)
        let payload = try req.content.decode(CreateGuardrailRequest.self)
        let node = try IAMPolicyGate.node(resourceType: payload.nodeType, resourceId: payload.nodeId)
        try await requirePolicyAdmin(on: node, write: true, req: req)

        // Two input modes, mirroring roles (#605): the structured matchers (the
        // builder assembles the forbid) or a hand-written `cedarText`. Both at
        // once is ambiguous.
        let hasMatchers =
            payload.actions != nil || payload.principalMatch != nil || payload.resourceMatch != nil
        if hasMatchers, payload.cedarText != nil {
            throw GuardrailError.ambiguousInput
        }

        let principalMatch = try payload.principalMatch?.toMatch() ?? .any
        let resourceMatch = try payload.resourceMatch?.toMatch() ?? .any

        // The guardrail and the version bump commit together: a ceiling that
        // exists under a version nobody bumped is a ceiling the replicas never
        // recompile against.
        let guardrail = try await PolicySetVersionService.withPolicySetChange(on: req.db) { db in
            let guardrail: Guardrail
            if let cedarText = payload.cedarText {
                guardrail = try await GuardrailStore.createAuthored(
                    name: payload.name,
                    description: payload.description,
                    node: node,
                    cedarText: cedarText,
                    enabled: payload.enabled ?? true,
                    createdBy: user.id,
                    engine: req.application.cedarEngine,
                    on: db
                )
            } else {
                guardrail = try await GuardrailStore.create(
                    name: payload.name,
                    description: payload.description,
                    effect: payload.effect,
                    node: node,
                    actions: payload.actions ?? [],
                    principalMatch: principalMatch,
                    resourceMatch: resourceMatch,
                    enabled: payload.enabled ?? true,
                    createdBy: user.id,
                    on: db
                )
            }
            try await PolicySetVersionService.bump(
                reason: "guardrail created: \(payload.name)", changedBy: user.id, on: db)
            return guardrail
        }
        await req.application.announcePolicySetChange()

        let response = Response(status: .created)
        try response.content.encode(
            GuardrailWriteResponse(
                guardrail: try await dto(guardrail, on: req.db),
                shadowedBindings: try await shadowed(by: guardrail, req: req)
            ))
        return response
    }

    /// PATCH /api/iam/guardrails/:guardrailID
    func update(req: Request) async throws -> GuardrailWriteResponse {
        let user = try requireUser(req)
        let existing = try await find(req)
        try await requirePolicyAdmin(on: try nodeOf(existing), write: true, req: req)

        let payload = try req.content.decode(UpdateGuardrailRequest.self)
        let principalMatch = try payload.principalMatch?.toMatch()
        let resourceMatch = try payload.resourceMatch?.toMatch()
        let name = existing.name
        guard let id = existing.id else {
            throw Abort(.internalServerError, reason: "Guardrail row is missing its id")
        }

        let updated = try await PolicySetVersionService.withPolicySetChange(on: req.db) { db in
            // Re-read inside the transaction so the update and the version bump
            // see the same row — and so a retried attempt starts from the row
            // as it is now, not from a copy loaded before the first try.
            guard let guardrail = try await Guardrail.find(id, on: db) else {
                throw Abort(.notFound, reason: "Guardrail not found")
            }
            let updated = try await GuardrailStore.update(
                guardrail,
                description: payload.description,
                actions: payload.actions,
                principalMatch: principalMatch,
                resourceMatch: resourceMatch,
                cedarText: payload.cedarText,
                enabled: payload.enabled,
                engine: req.application.cedarEngine,
                on: db
            )
            try await PolicySetVersionService.bump(
                reason: "guardrail updated: \(name)", changedBy: user.id, on: db)
            return updated
        }
        await req.application.announcePolicySetChange()

        return GuardrailWriteResponse(
            guardrail: try await dto(updated, on: req.db),
            shadowedBindings: try await shadowed(by: updated, req: req)
        )
    }

    /// DELETE /api/iam/guardrails/:guardrailID
    func delete(req: Request) async throws -> HTTPStatus {
        let user = try requireUser(req)
        let guardrail = try await find(req)
        try await requirePolicyAdmin(on: try nodeOf(guardrail), write: true, req: req)

        let name = guardrail.name
        guard let id = guardrail.id else {
            throw Abort(.internalServerError, reason: "Guardrail row is missing its id")
        }
        try await PolicySetVersionService.withPolicySetChange(on: req.db) { db in
            try await Guardrail.query(on: db).filter(\.$id == id).delete()
            try await PolicySetVersionService.bump(
                reason: "guardrail deleted: \(name)", changedBy: user.id, on: db)
        }
        await req.application.announcePolicySetChange()

        return .noContent
    }

    /// GET /api/iam/policy-set/version
    ///
    /// The version stamped into decision logs and used to invalidate each
    /// replica's compiled policy set. System-admin only: it describes the
    /// deployment, not any one organization's policy.
    func policySetVersion(req: Request) async throws -> PolicySetVersionResponse {
        let user = try requireUser(req)
        guard user.isSystemAdmin else {
            throw Abort(.forbidden, reason: "Reading the policy-set version requires system admin")
        }
        let latest = try await PolicySetVersion.query(on: req.db)
            .sort(\.$version, .descending)
            .first()
        return PolicySetVersionResponse(
            version: latest?.version ?? 0,
            replicaVersion: await req.application.policySetVersion.currentVersion,
            latest: latest
        )
    }

    // MARK: - Helpers

    private func requireUser(_ req: Request) throws -> User {
        guard let user = req.auth.get(User.self) else { throw Abort(.unauthorized) }
        return user
    }

    private func find(_ req: Request) async throws -> Guardrail {
        guard let id = req.parameters.get("guardrailID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Guardrail id must be a UUID")
        }
        guard let guardrail = try await Guardrail.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "Guardrail not found")
        }
        return guardrail
    }

    /// The grants a just-written ceiling narrows.
    ///
    /// Runs after the write has committed, so an unavailable solver cannot
    /// turn a guardrail write into a failure: the ceiling is already in force
    /// either way, and the report is a courtesy the write does not depend on.
    /// This is the opposite posture from binding writes, and deliberately so —
    /// there, the analysis is the thing being decided.
    private func shadowed(by guardrail: Guardrail, req: Request) async throws
        -> [GuardrailWriteCheck.ShadowedBinding]
    {
        do {
            let shadowed = try await GuardrailWriteCheck.shadowedBindings(
                by: guardrail,
                analyzer: req.application.guardrailAnalyzer,
                on: req.db,
                logger: req.logger
            )
            for binding in shadowed {
                req.logger.notice(
                    "Guardrail write narrowed an existing binding",
                    metadata: [
                        "guardrail": .string(guardrail.name),
                        "principal": .string("\(binding.principalType.rawValue)/\(binding.principalID)"),
                        "role": .string(binding.role.rawValue),
                        "node": .string("\(binding.node.type.rawValue)/\(binding.node.id)"),
                    ])
            }
            return shadowed
        } catch {
            req.logger.error(
                "Could not determine which bindings this guardrail narrows",
                metadata: [
                    "guardrail": .string(guardrail.name),
                    "error": .string("\(error)"),
                ])
            return []
        }
    }

    private func nodeOf(_ guardrail: Guardrail) throws -> IAMNode {
        guard let node = guardrail.node else {
            throw Abort(.internalServerError, reason: "Guardrail row names an unknown node type")
        }
        return node
    }

    /// A guardrail as a DTO, with its generated Cedar forbid attached.
    private func dto(_ guardrail: Guardrail, on db: any Database) async throws -> GuardrailDTO {
        try GuardrailDTO(guardrail, cedarText: try await cedarText(for: guardrail, on: db))
    }

    /// A batch of guardrails as DTOs, each with its generated forbid.
    private func dtos(_ guardrails: [Guardrail], on db: any Database) async throws -> [GuardrailDTO] {
        var result: [GuardrailDTO] = []
        result.reserveCapacity(guardrails.count)
        for guardrail in guardrails {
            result.append(try await dto(guardrail, on: db))
        }
        return result
    }

    /// The Cedar `forbid` a guardrail compiles to, for display. The stored
    /// column is the source of truth since #610 (matcher-generated or authored);
    /// a null column — a row predating the migration — is regenerated from the
    /// matchers on the fly, the same generation the write path and the boot
    /// backfill use, so what the UI shows is what the evaluator enforces.
    private func cedarText(for guardrail: Guardrail, on db: any Database) async throws -> String? {
        if let stored = guardrail.cedarText, !stored.isEmpty { return stored }
        return try await GuardrailRendering.cedarText(for: guardrail, on: db)
    }

    /// Reading a node's guardrails is `iam:readPolicy`; changing them is
    /// `iam:setPolicy`. Both are admin-role actions, evaluated through the
    /// policy set (so system admins flow through `platform-system-admin` and
    /// appear in decision logs).
    private func requirePolicyAdmin(on node: IAMNode, write: Bool, req: Request) async throws {
        let reason = "Managing guardrails requires admin on the node or a container above it"
        if write {
            try await IAMPolicyGate.requirePolicyWrite(on: node, deniedReason: reason, req: req)
        } else {
            try await IAMPolicyGate.requirePolicyRead(on: node, deniedReason: reason, req: req)
        }
    }
}
