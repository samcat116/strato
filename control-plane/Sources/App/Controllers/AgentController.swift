import Fluent
import StratoShared
import Vapor

struct AgentController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let agents = routes.grouped("api", "agents")

        // Agent enrollment endpoints (SPIRE node provisioning). Deliberately a
        // sibling collection rather than `/api/agents/enrollments`: an
        // enrollment is its own resource with its own lifecycle, and nesting it
        // would put the constant `enrollments` in the slot that otherwise holds
        // an agent id, producing ambiguous path templates (issue #595).
        let enrollmentRoutes = routes.grouped("api", "agent-enrollments")
        enrollmentRoutes.post(use: createEnrollment)
        enrollmentRoutes.get(use: listEnrollments)
        enrollmentRoutes.delete(":enrollmentId", use: revokeEnrollment)

        // Agent management endpoints
        agents.get(use: listAgents)
        agents.get(":agentId", use: getAgent)
        agents.delete(":agentId", use: deregisterAgent)
        agents.post(":agentId", "actions", "force-offline", use: forceAgentOffline)
        agents.post(":agentId", "actions", "update", use: updateAgent)
        agents.patch(":agentId", use: patchAgent)
        // Scope reassignment corrects the migration backfill's oldest-org
        // guess on multi-org installs; deliberately system-admin only (it
        // moves dedicated capacity between tenants).
        agents.patch(":agentId", "organization", use: reassignOrganization)
    }

    // MARK: - Authorization

    /// Agent management is delegated to the owning organization: enrolling a
    /// node or force-offlining agents is scoped to the org/OU
    /// whose capacity it is (`manage_agents`), and system admins retain
    /// unconditional access. Defense in depth — do not rely on route-level
    /// middleware.
    private func requireUser(_ req: Request) throws -> User {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        return user
    }

    private func requireSystemAdmin(_ req: Request) throws {
        // The decision-marking gate, so admin-only mutations (scopeless
        // enrollments, org reassignment) satisfy the middleware's
        // handler-evaluated assertion.
        _ = try req.requireSystemAdmin()
    }

    /// The (resourceType, id) pair naming the scope's owning node for
    /// permission checks against the IAM hierarchy.

    /// `manage_agents` on the given org/OU scope (system admins pass through
    /// the evaluator's tier-1 policy).
    private func requireManageAgents(_ req: Request, scope: OrganizationScope) async throws {
        let resource = scope.checkResource
        let allowed = try await req.can("manage_agents", on: resource.type, id: resource.id.uuidString)
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have permission to manage agents for this organization")
        }
    }

    /// The given permission on the agent itself (resolved through the
    /// agent's parent scope in the IAM tree).
    private func requireAgentPermission(_ req: Request, agent: Agent, permission: String) async throws {
        // A pre-scoping agent belongs to no org: there is nothing to evaluate
        // against (the evaluator fails closed on its truncated ancestor
        // chain), so only system admins may touch it — the decision-marking
        // gate, mirroring scopeless enrollments. This is what keeps orphaned
        // agents repairable (deregister, reassign) at all.
        guard agent.organizationScope != nil else {
            _ = try req.requireSystemAdmin("This agent has no owning organization")
            return
        }
        let allowed = try await req.can(permission, on: "agent", id: try agent.requireID().uuidString)
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have '\(permission)' permission on this agent")
        }
    }

    /// Whether SPIRE mTLS authentication is enabled but the registration API
    /// is not configured — the state in which agents may hold SPIRE-issued
    /// identities that this control plane cannot revoke. Revocation paths must
    /// fail closed here rather than delete our records and silently leave the
    /// node able to renew SVIDs. Deployments that manage SPIRE entries out of
    /// band can acknowledge with `?skipSpireDeprovision=true`.
    private func spireDeprovisioningUnavailable(_ req: Request) async -> Bool {
        guard req.application.spireRegistrationService == nil,
            let spireService = req.application.spireService
        else { return false }
        return await spireService.isEnabled
    }

    /// Pass `grantKnown: true` when a persisted record proves a SPIRE grant
    /// exists (an enrollment row): the guard then applies whenever
    /// the registration API is missing, regardless of how SPIRE auth happens
    /// to be configured right now. Without it, the guard falls back to
    /// inferring from SPIRE auth being enabled.
    private func requireSPIREDeprovisioningOrOverride(
        _ req: Request, action: String, grantKnown: Bool = false
    ) async throws {
        if grantKnown {
            guard req.application.spireRegistrationService == nil else { return }
        } else {
            guard await spireDeprovisioningUnavailable(req) else { return }
        }
        guard req.query[Bool.self, at: "skipSpireDeprovision"] == true else {
            throw Abort(
                .serviceUnavailable,
                reason:
                    "SPIRE authentication is enabled but SPIRE_SERVER_API_ADDRESS is not configured, so the SPIRE entries for this \(action) cannot be revoked and the node could keep renewing SVIDs. Configure the SPIRE server API, or remove the entries out of band and retry with ?skipSpireDeprovision=true."
            )
        }
        req.logger.warning(
            "Skipping SPIRE deprovisioning on operator override; ensure the entries are removed out of band",
            metadata: ["action": .string(action)])
    }

    // MARK: - Enrollment Management

    /// Base WebSocket URL agents should dial, embedded in bootstrap commands.
    ///
    /// The Host header only names whatever hop the request came in on — behind
    /// an ingress or port-forward that can be an address hypervisor hosts
    /// cannot reach, so an explicitly configured EXTERNAL_HOSTNAME wins.
    ///
    /// The scheme is always wss://: agents connect to the Envoy mTLS listener
    /// (EXTERNAL_HOSTNAME), which terminates TLS regardless of the
    /// browser-facing scheme, so this is wss:// even for an http://
    /// (localhost) origin.
    private func webSocketBaseURL(req: Request) -> String {
        let host =
            Environment.get("EXTERNAL_HOSTNAME").map(Self.sanitizedHost)
            ?? req.headers["host"].first
            ?? "localhost:8080"

        return "wss://\(host)"
    }

    /// Reduces an EXTERNAL_HOSTNAME value to bare host[:port]. Operators
    /// naturally set a full URL ("https://cp.example.com/") here; prepending
    /// a scheme to that verbatim would emit "wss://https://…", which the agent
    /// then rejects as an invalid control plane URL.
    static func sanitizedHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeRange = host.range(of: "://") {
            host = String(host[schemeRange.upperBound...])
        }
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        return host
    }

    func createEnrollment(req: Request) async throws -> AgentEnrollmentResponse {
        let createRequest = try req.content.decode(CreateAgentEnrollmentRequest.self)
        try createRequest.validate()

        // Enrolling a node *is* provisioning it in SPIRE, so an unconfigured
        // SPIRE server means there is no way to enroll an agent at all. Fail
        // naming the missing configuration rather than with an opaque 502 out
        // of the provisioning call below.
        guard let spire = req.application.spireRegistrationService else {
            throw Abort(
                .serviceUnavailable,
                reason:
                    "Agent enrollment requires SPIRE. Set SPIRE_ENABLED=true and SPIRE_SERVER_API_ADDRESS on the control plane."
            )
        }

        // Resolve and authorize the owning scope before anything else: the
        // enrollment's org is what the registering agent becomes dedicated to.
        let scope = try createRequest.organizationScope()
        try await scope.validateExists(on: req.db)
        try await requireManageAgents(req, scope: scope)

        // Names are unique per trust domain, not globally (issue #613): with a
        // trust domain per organization, two organizations may each enroll an
        // `agent-1` without either shadowing the other. Until per-org domains
        // are switched on this is the single platform domain, so the checks are
        // exactly as global as they were.
        let trustDomain = spire.trustDomain

        // Check if agent name is already in use by an existing agent
        let existingAgent = try await Agent.query(on: req.db)
            .filter(\.$trustDomain == trustDomain)
            .filter(\.$name == createRequest.agentName)
            .first()

        if existingAgent != nil {
            throw Abort(.conflict, reason: "Agent name '\(createRequest.agentName)' is already registered")
        }

        // One enrollment per name per trust domain (the pair is unique).
        // Re-enrolling a node means revoking the old one first, so its SPIRE
        // grant is withdrawn rather than orphaned alongside a second grant for
        // the same identity.
        let existingEnrollment = try await AgentEnrollment.query(on: req.db)
            .filter(\.$trustDomain == trustDomain)
            .filter(\.$agentName == createRequest.agentName)
            .first()

        if existingEnrollment != nil {
            throw Abort(
                .conflict,
                reason:
                    "An enrollment already exists for agent '\(createRequest.agentName)'. Revoke it before enrolling again."
            )
        }

        let expirationHours = createRequest.expirationHours ?? 1

        // Every enrollment joins a site (validated as present above). Resolve
        // it here so a typo'd id fails the request — and require it to belong to
        // the enrollment's organization: a site is one OVN deployment owned by
        // one org, so a foreign agent joining it would mix tenants on a shared
        // SDN. The caller also needs manage on the site itself (not just
        // manage_agents on the enrollment's scope): with agents and sites
        // delegated to different OUs of one org, an enrollment-carried site pin
        // must not admit an agent into a sibling OU's fabric that the site
        // membership endpoint would refuse.
        guard let siteId = createRequest.siteId else {
            throw Abort(.badRequest, reason: "A site is required to enroll an agent")
        }
        guard let site = try await Site.find(siteId, on: req.db) else {
            throw Abort(.badRequest, reason: "Site \(siteId) does not exist")
        }
        guard let siteScope = site.organizationScope,
            try await siteScope.contains(scope, on: req.db)
        else {
            throw Abort(
                .badRequest,
                reason: "Site \(siteId)'s organization scope does not contain the enrollment's")
        }
        let siteAllowed = try await req.can("manage", on: "site", id: siteId.uuidString)
        guard siteAllowed else {
            throw Abort(.forbidden, reason: "You don't have 'manage' permission on site \(siteId)")
        }

        // Provision the node in SPIRE first (join token + workload entry).
        // SPIRE is not transactional with our database, so order matters: if
        // provisioning fails nothing was persisted here, and if the save below
        // fails the provisioning is rolled back best-effort (a leftover entry
        // is reused on retry; the unredeemed join token just expires). The join
        // token shares the enrollment's expiry — one provisioning window.
        let provisioning: SPIREAgentProvisioning
        do {
            provisioning = try await spire.provisionAgent(
                named: createRequest.agentName,
                joinTokenTTLSeconds: Int32(expirationHours * 3600)
            )
        } catch let error as SPIRERegistrationError {
            throw Abort(.badRequest, reason: error.localizedDescription)
        } catch {
            req.logger.error(
                "SPIRE provisioning failed while creating an agent enrollment",
                metadata: [
                    "agentName": .string(createRequest.agentName),
                    "error": .string("\(error)"),
                ])
            throw Abort(
                .badGateway,
                reason: "SPIRE provisioning failed; no enrollment was created. \(error.localizedDescription)"
            )
        }

        let enrollment = AgentEnrollment(
            agentName: createRequest.agentName,
            spiffeID: provisioning.spiffeID,
            trustDomain: provisioning.trustDomain,
            expirationHours: expirationHours,
            siteID: createRequest.siteId,
            organizationScope: scope
        )

        do {
            try await enrollment.save(on: req.db)
        } catch {
            // A concurrent create for the same name can pass the pre-check above
            // and provision the same SPIRE entry (provisioning is idempotent by
            // name), leaving this request to lose the unique agent_name
            // constraint. Rolling back here would deprovision the entry the
            // *winner's* enrollment depends on, stranding a node whose operator
            // already holds a bootstrap command. Only withdraw the grant when no
            // other enrollment claims the name.
            //
            // `try?` over an optional-returning query yields a double optional;
            // flatten it so both "query failed" and "no row" read as unclaimed,
            // which keeps the rollback behaviour for a genuine save failure.
            let claimed =
                ((try? await AgentEnrollment.query(on: req.db)
                    .filter(\.$trustDomain == trustDomain)
                    .filter(\.$agentName == createRequest.agentName)
                    .first()) ?? nil) != nil

            if claimed {
                req.logger.warning(
                    "Concurrent enrollment won this agent name; leaving its SPIRE grant intact",
                    metadata: ["agentName": .string(createRequest.agentName)])
                throw Abort(
                    .conflict,
                    reason:
                        "An enrollment already exists for agent '\(createRequest.agentName)'. Revoke it before enrolling again."
                )
            }

            await spire.rollbackProvisioning(agentName: createRequest.agentName)
            throw error
        }

        req.logger.info(
            "Created agent enrollment",
            metadata: [
                "agentName": .string(createRequest.agentName),
                "enrollmentId": .string(enrollment.id?.uuidString ?? "unknown"),
                "spiffeId": .string(enrollment.spiffeID),
                "expiresAt": .string(enrollment.expiresAt?.description ?? "no expiration"),
            ])

        return try AgentEnrollmentResponse(
            from: enrollment,
            webSocketBaseURL: webSocketBaseURL(req: req),
            spire: provisioning
        )
    }

    /// GET /api/agent-enrollments
    /// Query params: organization_id (optional) — narrows to one org's hierarchy.
    func listEnrollments(req: Request) async throws -> [AgentEnrollmentListItem] {
        _ = try requireUser(req)
        let orgFilter = try await OrganizationAccessService.organizationListFilter(on: req)

        // Unlike Site and Agent, an enrollment stores its scope as plain columns
        // rather than parent relations.
        var query = AgentEnrollment.query(on: req.db).sort(\.$createdAt, .descending)
        if let orgFilter {
            query = query.group(.or) { group in
                group.filter(\.$organizationID == orgFilter.organizationID)
                if !orgFilter.organizationalUnitIDs.isEmpty {
                    group.filter(\.$organizationalUnitID ~~ orgFilter.organizationalUnitIDs)
                }
            }
        }
        let enrollments = try await query.all()

        // Every caller is filtered the same way: a scoped enrollment is a
        // `manage_agents` check on its org/OU, which the tier-1
        // `platform-system-admin` policy answers for admins — so their
        // fleet-wide view is an evaluator decision, logged and guardrail-bound,
        // not a skipped check. A scopeless row has no node to check and stays
        // system-admin only, matching the item endpoints' `requireSystemAdmin`.
        var visible: [AgentEnrollment] = []
        for enrollment in enrollments {
            guard let scope = enrollment.organizationScope else {
                if req.allowsScopelessPlatformRow() { visible.append(enrollment) }
                continue
            }
            let resource = scope.checkResource
            let ok = try await req.can("manage_agents", on: resource.type, id: resource.id.uuidString)
            if ok { visible.append(enrollment) }
        }

        // Never echo the SPIRE join token in a list response — it is shown
        // exactly once, at creation time.
        return try visible.map { try AgentEnrollmentListItem(from: $0) }
    }

    func revokeEnrollment(req: Request) async throws -> HTTPStatus {
        guard let enrollmentId = req.parameters.get("enrollmentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid enrollment ID")
        }

        guard let enrollment = try await AgentEnrollment.find(enrollmentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent enrollment not found")
        }

        if let scope = enrollment.organizationScope {
            try await requireManageAgents(req, scope: scope)
        } else {
            // Scopeless rows have no org to delegate revocation to.
            try requireSystemAdmin(req)
        }

        // Revoking withdraws the SPIRE grant this enrollment created — but only
        // while it still *owns* that grant. Once an Agent row exists for the
        // name, the node has attested and registered, and the entries belong to
        // that live agent: they are withdrawn by deregistering the agent
        // instead, so deprovisioning here would sever a running node.
        //
        // Expiry alone does NOT make a grant inert: the join token may have
        // been redeemed before it expired (spire-agent attests first; the Agent
        // row only appears once strato-agent registers), leaving entries and an
        // attested node that can still mint SVIDs. An expired enrollment with
        // no registered agent therefore still owns — and must revoke — its grant.
        //
        // Fail closed: if SPIRE is unreachable the enrollment stays revocable
        // later.
        // Scoped to the enrollment's own trust domain: a same-named agent in
        // another organization's domain is a different node entirely, and
        // matching it here would leave this enrollment's SPIRE grant standing.
        let agentIsRegistered =
            try await Agent.query(on: req.db)
            .filter(\.$trustDomain == enrollment.trustDomain)
            .filter(\.$name == enrollment.agentName)
            .first() != nil

        let enrollmentOwnsGrant = !agentIsRegistered

        if enrollmentOwnsGrant {
            try await requireSPIREDeprovisioningOrOverride(req, action: "agent enrollment", grantKnown: true)
        }

        if enrollmentOwnsGrant, let spire = req.application.spireRegistrationService {
            do {
                try await spire.deprovisionAgent(named: enrollment.agentName)
            } catch {
                req.logger.error(
                    "SPIRE deprovisioning failed while revoking an agent enrollment",
                    metadata: [
                        "agentName": .string(enrollment.agentName),
                        "error": .string("\(error)"),
                    ])
                throw Abort(
                    .badGateway,
                    reason:
                        "SPIRE deprovisioning failed; the enrollment was not revoked. Retry when the SPIRE server is reachable."
                )
            }
        }

        try await enrollment.delete(on: req.db)
        if enrollmentOwnsGrant {
            // No agent row exists, so any workload-registry row for the
            // identity is an orphan of the just-revoked SPIRE grant (#491).
            try await WorkloadRegistry.deregisterAgent(
                identity: AgentIdentity(trustDomain: enrollment.trustDomain, name: enrollment.agentName),
                on: req.db)
        }

        req.logger.info(
            "Revoked agent enrollment",
            metadata: [
                "enrollmentId": .string(enrollmentId.uuidString),
                "agentName": .string(enrollment.agentName),
            ])

        return .noContent
    }

    // MARK: - Agent Management

    /// GET /api/agents
    /// Query params: organization_id (optional) — narrows to one org's hierarchy.
    func listAgents(req: Request) async throws -> [AgentResponse] {
        _ = try requireUser(req)
        let orgFilter = try await OrganizationAccessService.organizationListFilter(on: req)

        var query = Agent.query(on: req.db).sort(\.$createdAt, .descending)
        if let orgFilter {
            query = query.group(.or) { group in
                group.filter(\.$organization.$id == orgFilter.organizationID)
                if !orgFilter.organizationalUnitIDs.isEmpty {
                    group.filter(\.$organizationalUnit.$id ~~ orgFilter.organizationalUnitIDs)
                }
            }
        }
        let agents = try await query.all()

        // Everyone is filtered the same way: `view` on the agent, resolved
        // through agent#parent (their orgs'/OUs' capacity). An admin's
        // fleet-wide view comes from the tier-1 `platform-system-admin` policy
        // inside the evaluator, so it is logged and a guardrail can narrow it.
        // A pre-scoping agent has no ancestor chain to evaluate against and
        // stays system-admin only, as in `requireAgentPermission`. An
        // organization_id filter narrows the query first — see listSites.
        var visible: [Agent] = []
        for agent in agents {
            guard let agentId = agent.id else { continue }
            guard agent.organizationScope != nil else {
                if req.allowsScopelessPlatformRow() { visible.append(agent) }
                continue
            }
            let ok = try await req.can("view", on: "agent", id: agentId.uuidString)
            if ok { visible.append(agent) }
        }

        // Update status based on heartbeat before returning
        for agent in visible {
            agent.updateStatusBasedOnHeartbeat()
        }

        for agent in visible {
            try await agent.save(on: req.db)
        }

        return try visible.map { try AgentResponse(from: $0) }
    }

    func getAgent(req: Request) async throws -> AgentResponse {
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }

        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }

        try await requireAgentPermission(req, agent: agent, permission: "view")

        agent.updateStatusBasedOnHeartbeat()
        try await agent.save(on: req.db)

        return try AgentResponse(from: agent)
    }

    func deregisterAgent(req: Request) async throws -> HTTPStatus {
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }

        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }

        try await requireAgentPermission(req, agent: agent, permission: "manage")

        // Never delete a site's designated network controller: the controller
        // reference deliberately has no FK (see CreateSite), so the site would
        // keep pointing at a vanished agent, no member could ever match it,
        // and reconciliation of the site's networks would silently stop.
        // Checked before SPIRE deprovisioning so the refusal has no side
        // effects.
        let controlledSites = try await Site.query(on: req.db)
            .filter(\.$networkControllerAgent.$id == agentId)
            .count()
        guard controlledSites == 0 else {
            throw Abort(
                .conflict,
                reason:
                    "Agent is a site's network controller; designate a replacement controller before deregistering it"
            )
        }

        // Remove the SPIRE workload entry before anything else, and fail
        // closed if that doesn't succeed: deregistering is the operator's
        // revocation lever, and deleting the row while the node can still
        // renew its SVID would leave a live credential with no visible owner.
        // That includes the misconfigured case where SPIRE auth is enabled but
        // the registration API is not set up at all.
        try await requireSPIREDeprovisioningOrOverride(req, action: "agent")

        if let spire = req.application.spireRegistrationService {
            do {
                try await spire.deprovisionAgent(named: agent.name)
            } catch {
                req.logger.error(
                    "SPIRE deprovisioning failed while deregistering agent",
                    metadata: [
                        "agentName": .string(agent.name),
                        "error": .string("\(error)"),
                    ])
                throw Abort(
                    .badGateway,
                    reason:
                        "SPIRE deprovisioning failed; the agent was not deregistered. Retry when the SPIRE server is reachable."
                )
            }
        }

        // Remove from in-memory registry if present
        await req.agentService.forceUnregisterAgent(agent.identity)

        // Delete from database, along with the workload-registry rows mapping
        // the agent's SPIFFE identity to it (issue #491) — the SPIRE entries
        // behind them were just deprovisioned.
        try await agent.delete(on: req.db)
        try await WorkloadRegistry.deregisterAgent(identity: agent.identity, on: req.db)

        // Deregistration retires the node: delete its enrollment so the name can
        // be enrolled again. Left behind, the row would block a fresh enrollment
        // through the one-per-name guard and lock the name permanently. SPIRE
        // entries for the name were already deprovisioned above, so the row
        // carries no external grant.
        try await AgentEnrollment.query(on: req.db)
            .filter(\.$trustDomain == agent.trustDomain)
            .filter(\.$agentName == agent.name)
            .delete()

        req.logger.info(
            "Deregistered agent",
            metadata: [
                "agentId": .string(agentId.uuidString),
                "agentName": .string(agent.name),
            ])

        return .noContent
    }

    func forceAgentOffline(req: Request) async throws -> HTTPStatus {
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }

        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }

        try await requireAgentPermission(req, agent: agent, permission: "manage")

        // Force agent offline in in-memory registry
        await req.agentService.forceUnregisterAgent(agent.identity)

        // Update database status
        agent.status = .offline
        try await agent.save(on: req.db)

        req.logger.info(
            "Forced agent offline",
            metadata: [
                "agentId": .string(agentId.uuidString),
                "agentName": .string(agent.name),
            ])

        return .noContent
    }

    // MARK: - Agent Update

    struct AgentUpdateRequest: Content {
        /// Proceed despite caveats the endpoint would otherwise refuse on:
        /// hosted sandboxes (whose runtime does not yet re-adopt them after a
        /// restart) and an agent already at the target version.
        var force: Bool?
        /// Explicit artifact override for deployments the URL-convention
        /// resolver can't serve (air-gapped without a mirror, main-branch
        /// builds, one-off testing). Requires `sha256`.
        var artifactUrl: String?
        /// Hex SHA-256 of the artifact at `artifactUrl`.
        var sha256: String?
        /// Shape of the explicit artifact: "tarball" (default, extract
        /// `tarballMember`) or "binary" (the download *is* the agent
        /// executable). Ignored without `artifactUrl` — release-resolved
        /// artifacts describe their own shape.
        var artifactKind: AgentUpdateArtifactKind?
        /// Member to extract from an explicit tarball artifact.
        /// Defaults to `strato-agent`.
        var tarballMember: String?
        /// Version label for an explicit artifact (informational; shown in
        /// logs and the response). Defaults to the configured target.
        var targetVersion: String?
    }

    struct AgentUpdateResponse: Content {
        let status: String
        let targetVersion: String
        /// Redacted form (query/userinfo stripped): a private mirror's
        /// manifest may resolve to presigned URLs, and this response goes to
        /// any delegated agent#manage holder, not just system admins.
        let artifactUrl: String
        let message: String?
    }

    /// Operator-triggered self-update of one agent (issue #432): resolves the
    /// release artifact for the agent's OS/arch, dispatches an
    /// `AgentUpdateMessage` over the agent socket (local or cross-replica via
    /// the RPC bridge), and reports the agent's own outcome synchronously.
    /// On success the agent restarts; the new binary proves itself by
    /// re-registering with its new version, which `registerAgent` logs.
    func updateAgent(req: Request) async throws -> AgentUpdateResponse {
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }
        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }

        // Restarting the agent briefly disconnects it and puts every hosted
        // workload through re-adoption, so this falls under the same
        // `agent:manage` check — and the same tier-1 foreign-workload forbid —
        // as force-offline and deregister.
        try await requireAgentPermission(req, agent: agent, permission: "manage")

        let request: AgentUpdateRequest
        if req.headers.contentType != nil {
            request = try req.content.decode(AgentUpdateRequest.self)
        } else {
            request = AgentUpdateRequest()
        }
        let force = request.force == true

        agent.updateStatusBasedOnHeartbeat()
        guard agent.isOnline else {
            throw Abort(.conflict, reason: "Agent is offline; it must be connected to receive an update")
        }

        // A pre-v6 agent cannot even decode the update envelope — it would
        // silently drop it and this request would only ever time out. Refuse
        // with the real reason instead.
        let wireVersion = agent.wireProtocolVersion ?? 0
        guard WireProtocol.supportsAgentUpdate(wireVersion) else {
            throw Abort(
                .conflict,
                reason:
                    "Agent registered with wire protocol v\(wireVersion), which predates remote updates (v\(WireProtocol.agentUpdateMinimumVersion)). Update it manually once (re-run install.sh, or pull a new image); remote updates work from then on."
            )
        }

        // VMs survive an agent restart regardless of hypervisor: QEMU and
        // Firecracker VMs are both re-adopted via their deterministic control
        // sockets (issue #433), so they need no acknowledgement. Sandboxes do:
        // their runtime driver (issue #421) hasn't landed, so restart-survival
        // is unproven — drop this guard only once it re-adopts them the same
        // way. Make the operator acknowledge that explicitly.
        if !force {
            let sandboxes = try await Sandbox.query(on: req.db)
                .filter(\.$hypervisorId == agentId.uuidString)
                .count()
            guard sandboxes == 0 else {
                throw Abort(
                    .conflict,
                    reason:
                        "Agent hosts \(sandboxes) sandbox(es), which the sandbox runtime does not yet re-adopt after an agent restart. Delete them, or pass force to proceed anyway."
                )
            }
        }

        let targetVersion: String
        let artifact: ResolvedAgentArtifact
        if let explicitURL = request.artifactUrl {
            // An explicit artifact is arbitrary code the agent will install and
            // run as itself on the hypervisor host — a strictly larger power
            // than `agent:manage`, so it is a distinct action rather than an
            // inline admin check. No seeded role carries it, which leaves the
            // tier-1 `platform-system-admin` policy as the only thing that
            // grants it today; a custom role can grant it deliberately, and a
            // guardrail can take it away.
            guard try await req.can("agent:updateArtifact", on: IAMNode(type: .agent, id: agentId)) else {
                throw Abort(
                    .forbidden,
                    reason:
                        "Explicit artifact overrides install an arbitrary binary on the host and require system admin. Omit artifactUrl to update along the release path."
                )
            }
            guard let explicitDigest = request.sha256.flatMap({ AgentUpdateArtifacts.parseChecksum($0) })
            else {
                throw Abort(.badRequest, reason: "artifactUrl requires a hex SHA-256 digest in sha256")
            }
            targetVersion = request.targetVersion ?? AgentVersionTarget.version ?? "unspecified"
            artifact = ResolvedAgentArtifact(
                url: explicitURL,
                sha256: explicitDigest,
                kind: request.artifactKind ?? .tarball,
                tarballMember: request.tarballMember ?? AgentUpdateArtifacts.defaultTarballMember
            )
        } else {
            guard let target = AgentVersionTarget.version else {
                throw Abort(
                    .badRequest,
                    reason:
                        "No agent target version is configured (dev build). Set AGENT_TARGET_VERSION, or pass artifactUrl and sha256 explicitly."
                )
            }
            if !force, !AgentVersionTarget.updateAvailable(agentVersion: agent.version, target: target) {
                throw Abort(
                    .conflict,
                    reason:
                        "Agent already runs the target version (\(agent.version)). Pass force to reinstall it anyway."
                )
            }
            guard let os = agent.hostOperatingSystem else {
                throw Abort(
                    .conflict,
                    reason:
                        "Agent has not reported its operating system; it must re-register with a build that does before its artifact can be resolved. Pass artifactUrl and sha256 to override."
                )
            }
            guard let architecture = agent.cpuArchitecture else {
                throw Abort(
                    .conflict,
                    reason:
                        "Agent has not reported its CPU architecture, so its artifact cannot be resolved. Pass artifactUrl and sha256 to override."
                )
            }
            targetVersion = target
            artifact = try await req.application.agentArtifactResolver.resolve(
                version: target,
                operatingSystem: os,
                architecture: architecture
            )
        }
        let artifactURL = artifact.url

        req.logger.info(
            "Dispatching agent update",
            metadata: [
                "agentId": .string(agentId.uuidString),
                "agentName": .string(agent.name),
                "currentVersion": .string(agent.version),
                "targetVersion": .string(targetVersion),
                // Redacted: explicit overrides may be presigned URLs whose
                // query string is a credential.
                "artifactUrl": .string(AgentUpdateMessage.redactURL(artifactURL)),
            ])

        let message = AgentUpdateMessage(
            targetVersion: targetVersion,
            artifactURL: artifact.url,
            sha256: artifact.sha256,
            artifactKind: artifact.kind,
            tarballMember: artifact.kind == .tarball ? artifact.tarballMember : nil
        )

        // Generous timeout: the reply comes only after the agent has
        // downloaded and verified the artifact.
        let response: AgentServiceResponse
        do {
            response = try await req.agentService.sendMessageToAgentWithResponse(
                message, agentId: agentId.uuidString, timeout: .seconds(300))
        } catch let error as AgentServiceError {
            switch error {
            case .requestTimeout:
                throw Abort(
                    .gatewayTimeout,
                    reason:
                        "The agent did not reply within the update window. The update may still complete — the agent re-registers with its new version if it does."
                )
            default:
                throw Abort(.badGateway, reason: "Could not reach the agent: \(error)")
            }
        }

        switch response {
        case .success:
            req.logger.notice(
                "Agent accepted update and is restarting",
                metadata: [
                    "agentId": .string(agentId.uuidString),
                    "agentName": .string(agent.name),
                    "targetVersion": .string(targetVersion),
                ])
            return AgentUpdateResponse(
                status: "updating",
                targetVersion: targetVersion,
                artifactUrl: AgentUpdateMessage.redactURL(artifactURL),
                message:
                    "Agent verified and installed the new binary and is restarting; it will re-register as \(targetVersion)."
            )
        case .error(let error, let details):
            throw Abort(
                .badGateway,
                reason: details.map { "\(error): \($0)" } ?? error)
        }
    }

    // MARK: - Agent Properties

    struct AgentPatchRequest: Content {
        /// Enroll in (or withdraw from) declarative auto-update (issue #434).
        var autoUpdate: Bool?
    }

    /// Updates mutable agent properties. Currently only `autoUpdate`; scoped
    /// to `agent#manage` like the imperative update action, since enrollment
    /// authorizes future restarts of this capacity.
    func patchAgent(req: Request) async throws -> AgentResponse {
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }
        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        try await requireAgentPermission(req, agent: agent, permission: "manage")

        let patch = try req.content.decode(AgentPatchRequest.self)

        if let autoUpdate = patch.autoUpdate, autoUpdate != agent.autoUpdate {
            agent.autoUpdate = autoUpdate
            if autoUpdate {
                // Fresh enrollment gets a fresh chance: a failure recorded
                // under a previous enrollment must not keep the fleet rollout
                // halted at an agent the operator just re-opted in.
                agent.updateFailureReason = nil
            } else {
                // Withdrawing clears any assignment: the next sync stops
                // carrying the desired update and the agent clears its
                // blocked status.
                agent.updateDesiredVersion = nil
                agent.updateAttemptedAt = nil
                agent.updateBlockedReason = nil
                agent.updateFailureReason = nil
            }
            try await agent.save(on: req.db)
            req.logger.info(
                "Agent auto-update toggled",
                metadata: [
                    "agentId": .string(agentId.uuidString),
                    "agentName": .string(agent.name),
                    "autoUpdate": .stringConvertible(autoUpdate),
                ])
            // Push a sync so a withdrawn agent stops seeing the desired
            // update now rather than on the next periodic backstop.
            await req.agentService.syncDesiredState(agentId: agentId.uuidString)
        }

        return try AgentResponse(from: agent)
    }

    // MARK: - Organization Reassignment

    struct ReassignAgentOrganizationRequest: Content {
        let organizationId: UUID?
        let organizationalUnitId: UUID?
    }

    /// Moves an agent's dedicated capacity to another org/OU. System-admin
    /// only: an org admin must not be able to pull another tenant's hardware
    /// into their own org (or donate theirs away). Same drain invariants as a
    /// token-driven move — no hosted VMs, not in a site.
    func reassignOrganization(req: Request) async throws -> AgentResponse {
        try requireSystemAdmin(req)

        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }
        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }

        let update = try req.content.decode(ReassignAgentOrganizationRequest.self)
        guard
            let scope = try OrganizationScope.from(
                organizationID: update.organizationId, organizationalUnitID: update.organizationalUnitId)
        else {
            throw Abort(.badRequest, reason: "Either organizationId or organizationalUnitId is required")
        }
        try await scope.validateExists(on: req.db)

        let previousScope = agent.organizationScope

        if scope == previousScope {
            return try AgentResponse(from: agent)
        }

        guard agent.$site.id == nil else {
            throw Abort(
                .conflict,
                reason: "Agent belongs to a site; remove it from the site before changing its organization")
        }
        let hostedVMs = try await VM.query(on: req.db)
            .filter(\.$hypervisorId == agentId.uuidString)
            .count()
        guard hostedVMs == 0 else {
            throw Abort(
                .conflict,
                reason: "Agent hosts \(hostedVMs) VM(s); migrate or delete them before changing its organization")
        }
        let hostedSandboxes = try await Sandbox.query(on: req.db)
            .filter(\.$hypervisorId == agentId.uuidString)
            .count()
        guard hostedSandboxes == 0 else {
            throw Abort(
                .conflict,
                reason:
                    "Agent hosts \(hostedSandboxes) sandbox(es); delete them before changing its organization"
            )
        }
        // Detached volumes anchor the old org's data to this hardware the
        // same way VMs do: moving the agent would strand them on foreign
        // capacity (their operations still target this agent by
        // hypervisorId) and block the new org's delegated admins behind the
        // foreign-workload guard.
        let storedVolumes = try await Volume.query(on: req.db)
            .filter(\.$hypervisorId == agentId.uuidString)
            .count()
        guard storedVolumes == 0 else {
            throw Abort(
                .conflict,
                reason:
                    "Agent stores \(storedVolumes) volume(s); migrate or delete them before changing its organization"
            )
        }

        agent.organizationScope = scope
        try await agent.save(on: req.db)

        req.logger.info(
            "Reassigned agent organization",
            metadata: [
                "agentId": .string(agentId.uuidString),
                "agentName": .string(agent.name),
            ])

        return try AgentResponse(from: agent)
    }
}
