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
        // Finishes a node's re-identification (STR-98): moves the workloads it
        // is demonstrably running off the agent record it was enrolled under
        // before.
        agents.post(":agentId", "actions", "adopt-workloads", use: adoptWorkloads)
        agents.patch(":agentId", use: patchAgent)
        // Scope reassignment corrects the migration backfill's oldest-org
        // guess on multi-org installs; deliberately system-admin only (it
        // moves dedicated capacity between tenants).
        agents.patch(":agentId", "organization", use: reassignOrganization)
    }

    // MARK: - Authorization
    //
    // Agent management is delegated to the owning organization: enrolling a
    // node or force-offlining agents is scoped to the org/OU whose capacity it
    // is (`manage_agents`), and system admins retain unconditional access.
    // Defense in depth — do not rely on route-level middleware.

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

    /// The SPIRE instance that issued `trustDomain`'s identities, or nil when
    /// the operator has explicitly accepted that its entries cannot be removed.
    ///
    /// The unknown-domain case is genuinely unrecoverable rather than
    /// transient: once an `org_trust_domains` row is gone — teardown completed,
    /// or it was never recorded — while an agent or enrollment still names that
    /// domain, no retry brings it back. Without an escape hatch the resource
    /// would be permanently undeletable, so this is the one deprovisioning
    /// failure `?skipSpireDeprovision=true` may override. "Server unreachable"
    /// deliberately still fails hard, because there retrying *is* the remedy.
    private func spireServiceForDeprovisioning(
        _ req: Request, registry: OrgSPIREClientRegistry, trustDomain: String, action: String
    ) async throws -> SPIRERegistrationService? {
        if let service = try await registry.service(forTrustDomain: trustDomain, on: req.db) {
            return service
        }
        guard req.query[Bool.self, at: "skipSpireDeprovision"] == true else {
            throw Abort(
                .serviceUnavailable,
                reason:
                    "No SPIRE instance is known for trust domain '\(trustDomain)', so the SPIRE entries for this "
                    + "\(action) cannot be revoked and the node could keep renewing SVIDs. Remove them out of band "
                    + "and retry with ?skipSpireDeprovision=true."
            )
        }
        req.logger.warning(
            "Skipping SPIRE deprovisioning for an unknown trust domain on operator override; ensure the entries are removed out of band",
            metadata: ["action": .string(action), "trustDomain": .string(trustDomain)])
        return nil
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
        guard let registry = OrgSPIREClientRegistry.fromApplication(req.application) else {
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

        // Which SPIRE instance owns this organization's identities. With
        // per-org trust domains (issue #615) that is the organization's own
        // instance; otherwise — and while its domain is still being
        // provisioned, if legacy enrollments are allowed — the platform one.
        let selection = try await registry.resolve(scope: scope, on: req.db)
        let spire = selection.service
        if let fallback = selection.platformFallback {
            req.logger.info(
                "Enrolling into the platform trust domain",
                metadata: [
                    "agentName": .string(createRequest.agentName),
                    "reason": .string(fallback.label),
                ])
        }

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
                joinTokenTTLSeconds: Int32(expirationHours * 3600),
                federatesWith: selection.federatesWith
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
            spire: provisioning,
            controlPlaneSPIFFEID: selection.controlPlaneSPIFFEID
        )
    }

    /// GET /api/agent-enrollments
    /// Query params: organization_id (optional) — narrows to one org's hierarchy;
    /// limit/offset (optional) — select the page.
    func listEnrollments(req: Request) async throws -> PagedResponse<AgentEnrollmentListItem> {
        let paging = try ListPaging.decode(from: req)
        let enrollments = try await visibleEnrollments(req: req)
        return paging.page(enrollments)
    }

    /// Every enrollment the caller may read, newest first, ready for slicing.
    func visibleEnrollments(req: Request) async throws -> [AgentEnrollmentListItem] {
        _ = try req.auth.require(User.self)
        let orgFilter = try await OrganizationAccessService.organizationListFilter(on: req)

        // Unlike Site and Agent, an enrollment stores its scope as plain columns
        // rather than parent relations.
        var query = AgentEnrollment.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
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
        // The scoped rows are decided in one batch (#687); a scopeless row has
        // no node to batch and is answered without the evaluator.
        //
        // `manage_agents` translates to `agent:manage` whichever kind of scope
        // owns the row, so org and folder nodes share one batch. Asking in the
        // action vocabulary directly is the same question `requireManageAgents`
        // asks through the translator — and the request memo is keyed on the
        // translated action, so a listed row and the item route it links to are
        // decided once, not twice.
        let manageable = try await req.canFilter(
            "agent:manage", on: enrollments.compactMap { $0.organizationScope?.checkNode })
        let visible = enrollments.filter { enrollment in
            guard let scope = enrollment.organizationScope else { return req.allowsScopelessPlatformRow() }
            return manageable.contains(scope.checkNode)
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

        // Withdraw the grant from the SPIRE instance that actually issued it —
        // the enrollment records its trust domain, which with per-org domains
        // (issue #615) may not be the platform one. Deprovisioning against the
        // wrong server deletes nothing and reports success, leaving the node
        // able to keep renewing SVIDs.
        if enrollmentOwnsGrant, let registry = OrgSPIREClientRegistry.fromApplication(req.application) {
            // Resolved outside the catch below so an unknown trust domain
            // reaches the operator as itself — and is overridable — rather than
            // as a generic "retry when the server is reachable". The remedies
            // are different, and only one of them can ever succeed.
            let spire = try await spireServiceForDeprovisioning(
                req, registry: registry, trustDomain: enrollment.trustDomain, action: "agent enrollment")
            do {
                try await spire?.deprovisionAgent(named: enrollment.agentName)
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
    /// Query params: organization_id (optional) — narrows to one org's hierarchy;
    /// limit/offset (optional) — select the page.
    func listAgents(req: Request) async throws -> PagedResponse<AgentResponse> {
        let paging = try ListPaging.decode(from: req)
        let agents = try await visibleAgents(req: req)
        return paging.page(agents)
    }

    /// Every agent the caller may read, newest first, ready for slicing.
    func visibleAgents(req: Request) async throws -> [AgentResponse] {
        _ = try req.auth.require(User.self)
        let orgFilter = try await OrganizationAccessService.organizationListFilter(on: req)

        var query = Agent.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
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
        // The scoped rows are decided in one batch (#687); a scopeless row has
        // no node to batch and is answered without the evaluator.
        let readable = try await req.canFilter(
            "agent:read",
            on: agents.compactMap { agent in
                guard agent.organizationScope != nil, let id = agent.id else { return nil }
                return IAMNode(type: .agent, id: id)
            })
        var visible: [Agent] = []
        for agent in agents {
            guard let agentId = agent.id else { continue }
            guard agent.organizationScope != nil else {
                if req.allowsScopelessPlatformRow() { visible.append(agent) }
                continue
            }
            if readable.contains(IAMNode(type: .agent, id: agentId)) { visible.append(agent) }
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

        // Workloads this agent holds that the control plane refused to
        // authorize tearing down (STR-98). Only on the detail view: the list
        // endpoint shouldn't pay for a claim query per agent, and this is
        // something an operator investigates one host at a time.
        let held = try await AgentWorkloadClaim.query(on: req.db)
            .filter(\.$agentId == agentId.uuidString)
            .filter(\.$disposition == .held)
            .sort(\.$firstSeenAt)
            .all()
            .map(AgentResponse.HeldWorkloadSummary.init(from:))

        return try AgentResponse(from: agent, heldWorkloads: held)
    }

    // MARK: - Workload adoption (STR-98)

    struct AdoptWorkloadsRequest: Content {
        /// The agent record whose placements should move to this agent.
        var fromAgentId: UUID
    }

    struct AdoptWorkloadsResponse: Content {
        let adoptedVMs: Int
        let adoptedSandboxes: Int
        let adoptedVolumes: Int
        /// Workloads still placed on `fromAgentId` that this agent does not
        /// report holding, so they were left alone. Named for what it is: a
        /// plain "skipped" reads as "left stranded on a dead record", and
        /// these may equally be workloads correctly running somewhere else.
        let skippedUnclaimed: Int
    }

    /// Move a volume's replica rows from one agent record to another.
    ///
    /// `volume_replicas` is unique on `(volume_id, agent_id)`, so a straight
    /// update collides when the target already has a replica of this volume —
    /// possible on a replicated pool. There the source row is redundant rather
    /// than movable: drop it and keep the target's own record of the copy.
    private static func repointReplicas(
        volumeID: UUID, from sourceId: String, to targetId: String, on db: Database
    ) async throws {
        let targetExists =
            try await VolumeReplica.query(on: db)
            .filter(\.$volume.$id == volumeID)
            .filter(\.$agentId == targetId)
            .count() > 0
        if targetExists {
            try await VolumeReplica.query(on: db)
                .filter(\.$volume.$id == volumeID)
                .filter(\.$agentId == sourceId)
                .delete()
            return
        }
        try await VolumeReplica.query(on: db)
            .filter(\.$volume.$id == volumeID)
            .filter(\.$agentId == sourceId)
            .set(\.$agentId, to: targetId)
            .update()
    }

    /// Re-point workloads from a superseded agent record onto the agent that
    /// is actually running them.
    ///
    /// `Agent` rows are keyed by `(trust_domain, name)`, and `VM.hypervisorId`
    /// stores the row's UUID. Re-enrolling a node under a corrected name — or
    /// moving it to its organization's trust domain — therefore mints a *new*
    /// row, and nothing re-points the workloads: the node comes back holding
    /// every VM it had, with the database insisting they live on a record that
    /// no longer connects. Before STR-98 the node's first sync listed nothing
    /// and it destroyed all of them.
    ///
    /// Now it holds them and reports them, and this endpoint is how an
    /// operator finishes the move. The evidence is what bounds it: only
    /// workloads the target agent *reports holding* (a `held` claim) and that
    /// are *currently placed* on `fromAgentId` move. There is no way to use
    /// this to point a workload at a host that isn't running it.
    func adoptWorkloads(req: Request) async throws -> AdoptWorkloadsResponse {
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }
        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        try await requireAgentPermission(req, agent: agent, permission: "manage")

        let body = try req.content.decode(AdoptWorkloadsRequest.self)
        let targetId = agentId.uuidString
        let sourceId = body.fromAgentId.uuidString
        guard sourceId != targetId else {
            throw Abort(.badRequest, reason: "An agent cannot adopt workloads from itself")
        }

        // The source record is a subject of this call, not just a parameter:
        // adoption moves rows *off* it. Authorize it in its own right, and
        // refuse to move workloads across an organization boundary — the
        // trust-domain migration this exists for keeps a node in its own org,
        // so a mismatch here is an operator mistake, not a supported case.
        guard let sourceAgent = try await Agent.find(body.fromAgentId, on: req.db) else {
            throw Abort(.notFound, reason: "Source agent not found")
        }
        try await requireAgentPermission(req, agent: sourceAgent, permission: "manage")
        // Compared at the root org, not the exact scope node: re-enrolling a
        // node into a different OU of the same organization is a legitimate
        // move, while landing one tenant's workload rows on another tenant's
        // agent record is not.
        let sourceOrg = try await sourceAgent.rootOrganizationID(on: req.db)
        let targetOrg = try await agent.rootOrganizationID(on: req.db)
        guard sourceOrg == targetOrg else {
            throw Abort(
                .conflict,
                reason: "Cannot adopt workloads across organizations: "
                    + "\(sourceAgent.name) and \(agent.name) belong to different organizations")
        }

        // Only claims that name this source: the operator is confirming one
        // specific re-identification, not every stray the host holds.
        let claims = try await AgentWorkloadClaim.query(on: req.db)
            .filter(\.$agentId == targetId)
            .filter(\.$disposition == .held)
            .all()
            .filter { $0.placedOnAgentId == sourceId }
        guard !claims.isEmpty else {
            throw Abort(
                .conflict,
                reason: "This agent does not report holding any workloads placed on that agent record")
        }

        let claimedVMIDs = Set(claims.filter { $0.resourceKind == .virtualMachine }.map(\.resourceID))
        let claimedSandboxIDs = Set(claims.filter { $0.resourceKind == .sandbox }.map(\.resourceID))

        let counts = try await req.db.transaction { db -> AdoptWorkloadsResponse in
            var adoptedVMs = 0
            var adoptedSandboxes = 0
            var adoptedVolumes = 0
            var skippedUnclaimed = 0

            let sourceVMs = try await VM.query(on: db).filter(\.$hypervisorId == sourceId).all()
            for vm in sourceVMs {
                guard let vmID = vm.id, claimedVMIDs.contains(vmID) else {
                    skippedUnclaimed += 1
                    continue
                }
                vm.hypervisorId = targetId
                try await vm.save(on: db)
                adoptedVMs += 1
            }

            let sourceSandboxes = try await Sandbox.query(on: db).filter(\.$hypervisorId == sourceId).all()
            for sandbox in sourceSandboxes {
                guard let sandboxID = sandbox.id, claimedSandboxIDs.contains(sandboxID) else {
                    skippedUnclaimed += 1
                    continue
                }
                sandbox.hypervisorId = targetId
                try await sandbox.save(on: db)
                adoptedSandboxes += 1
            }

            // Volumes are files on the host, so they move with it — but by
            // *placement*, not by attachment. Three columns decide where a
            // volume operation is dispatched and all three have to move
            // together, or the endpoint reports a move it didn't finish:
            //
            // * `VolumeReplica.agentId` — what `VolumeService.placement(of:)`
            //   consults *first*. Every volume created through `VolumeService`
            //   has a replica row, so re-pointing `hypervisorId` alone would
            //   leave every snapshot/resize/attach still dispatching to the
            //   superseded record, hanging until the stuck-operation sweep.
            // * `Volume.hypervisorId` — the fallback for rows with no replica.
            // * `Volume.attachedAgentId` — set from the VM's placement at
            //   attach time; left behind it would disagree with `hypervisorId`
            //   on the same row.
            //
            // Detached volumes move too: their files are on the adopting host
            // like everything else the source record owned, and leaving them
            // would point a later attach at a dead record. A volume attached to
            // a VM that stayed behind is the one case that must not move.
            let sourceVolumes = try await Volume.query(on: db)
                .filter(\.$hypervisorId == sourceId)
                .all()
            for volume in sourceVolumes {
                if let attachedVMID = volume.$vm.id, !claimedVMIDs.contains(attachedVMID) {
                    continue
                }
                guard let volumeID = volume.id else { continue }
                volume.hypervisorId = targetId
                if volume.attachedAgentId == sourceId {
                    volume.attachedAgentId = targetId
                }
                try await volume.save(on: db)
                try await Self.repointReplicas(
                    volumeID: volumeID, from: sourceId, to: targetId, on: db)
                adoptedVolumes += 1
            }

            // The claims are consumed: the next report re-derives whatever is
            // still unaccounted for, and these workloads now appear in the
            // target's own sync.
            for claim in claims {
                try await claim.delete(on: db)
            }

            return AdoptWorkloadsResponse(
                adoptedVMs: adoptedVMs,
                adoptedSandboxes: adoptedSandboxes,
                adoptedVolumes: adoptedVolumes,
                skippedUnclaimed: skippedUnclaimed)
        }

        req.logger.notice(
            "Adopted workloads onto a re-enrolled agent record",
            metadata: [
                "agentId": .string(targetId),
                "agentName": .string(agent.name),
                "fromAgentId": .string(sourceId),
                "adoptedVMs": .stringConvertible(counts.adoptedVMs),
                "adoptedSandboxes": .stringConvertible(counts.adoptedSandboxes),
                "adoptedVolumes": .stringConvertible(counts.adoptedVolumes),
                "skippedUnclaimed": .stringConvertible(counts.skippedUnclaimed),
            ])

        // Both sides need a fresh sync: the target so it stops holding
        // workloads nothing described, the source (if it is somehow still
        // connected) so it stops being told it owns them.
        await req.agentService.syncDesiredState(agentId: targetId)
        await req.agentService.syncDesiredState(agentId: sourceId)

        return counts
    }

    func deregisterAgent(req: Request) async throws -> HTTPStatus {
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }

        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }

        try await requireAgentPermission(req, agent: agent, permission: "manage")

        // Never delete a site's designated network controller while the site
        // still has other members: the controller reference deliberately has
        // no FK (see CreateSite), so the site would keep pointing at a
        // vanished agent, no member could ever match it, and reconciliation of
        // the site's networks would silently stop. The site's *last* member is
        // the exception — since the first node to join a site is designated
        // automatically (issue #743), refusing there would make a single-node
        // site's only agent undeletable, and once it is gone the site has
        // nothing left to reconcile. Its designation is cleared below instead.
        // Checked before SPIRE deprovisioning so the refusal has no side
        // effects.
        let controlledSites = try await Site.query(on: req.db)
            .filter(\.$networkControllerAgent.$id == agentId)
            .all()
        for site in controlledSites {
            let remainingMembers = try await Agent.query(on: req.db)
                .filter(\.$site.$id == site.requireID())
                .filter(\.$id != agentId)
                .count()
            guard remainingMembers == 0 else {
                throw Abort(
                    .conflict,
                    reason:
                        "Agent is a site's network controller; designate a replacement controller before deregistering it"
                )
            }
        }

        // Remove the SPIRE workload entry before anything else, and fail
        // closed if that doesn't succeed: deregistering is the operator's
        // revocation lever, and deleting the row while the node can still
        // renew its SVID would leave a live credential with no visible owner.
        // That includes the misconfigured case where SPIRE auth is enabled but
        // the registration API is not set up at all.
        try await requireSPIREDeprovisioningOrOverride(req, action: "agent")

        // Against the SPIRE instance that issued this agent's identity: the
        // agent row records its trust domain, which with per-org domains
        // (issue #615) may not be the platform one.
        if let registry = OrgSPIREClientRegistry.fromApplication(req.application) {
            // Resolved outside the catch below so an unknown trust domain is
            // reported as itself — and is overridable — rather than as an
            // unreachable server that retrying would fix.
            let spire = try await spireServiceForDeprovisioning(
                req, registry: registry, trustDomain: agent.trustDomain, action: "agent")
            do {
                try await spire?.deprovisionAgent(named: agent.name)
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

        // Give up the designations the guard above allowed — only sites this
        // agent was the last member of get here — so none is left pointing at
        // the row that is about to vanish.
        for site in controlledSites {
            site.$networkControllerAgent.id = nil
            try await site.save(on: req.db)
        }

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
        /// Proceed despite the one caveat the endpoint refuses on: hosted
        /// sandboxes, whose runtime does not yet re-adopt them after a restart.
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
        /// Version label for an explicit artifact. Defaults to the configured
        /// target. **Load-bearing**, unlike the imperative dispatch this
        /// replaced: convergence is "the agent re-registered at this version",
        /// so a label the artifact's binary does not report leaves the update
        /// stuck until the health budget records a failure.
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

    /// Operator-triggered self-update of one agent (issue #432), as desired
    /// state (ADR 0001 stage 6): assigns the target version — and any explicit
    /// artifact — to the agent row and nudges a sync, which carries it as
    /// `desiredAgentUpdate`. The agent converges when its own preconditions
    /// allow and proves the update by re-registering with the new version.
    ///
    /// This used to dispatch an imperative `agent_update` over the socket and
    /// block on the reply, which made the outcome synchronous at the cost of a
    /// 300s hostage request, a cross-replica RPC hop when the socket lived
    /// elsewhere, and an update that vanished if the agent was mid-reconnect.
    /// The response is now a 202: the assignment is durable on the row, so it
    /// survives disconnects and replica death, and the caller watches
    /// `updateDesiredVersion` / `updateBlockedReason` / `updateFailureReason`
    /// on the agent (the same fields the fleet rollout has always used).
    func updateAgent(req: Request) async throws -> Response {
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

        // A pre-v7 agent decodes the sync but ignores `desiredAgentUpdate`, so
        // the assignment would sit there converging on nothing until the health
        // budget recorded a failure. Refuse with the real reason instead.
        let wireVersion = agent.wireProtocolVersion ?? 0
        guard WireProtocol.supportsDesiredAgentUpdate(wireVersion) else {
            throw Abort(
                .conflict,
                reason:
                    "Agent registered with wire protocol v\(wireVersion), which predates remote updates (v\(WireProtocol.desiredAgentUpdateMinimumVersion)). Update it manually once (re-run install.sh, or pull a new image); remote updates work from then on."
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
        // Only an explicit override is pinned to the row. A release artifact is
        // resolved here to fail fast on a platform the release does not serve,
        // then thrown away: sync assembly re-resolves it every time, so a
        // long-assigned update never carries a stale (possibly presigned) link.
        let artifactOverride: ResolvedAgentArtifact?
        let artifactURL: String
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
            // The label is what convergence is measured against, so it cannot
            // be invented. A deployment with no target of its own (a dev build,
            // or a main-branch image — exactly when overrides get used) must
            // say what the artifact's binary will report.
            guard let explicitVersion = request.targetVersion ?? AgentVersionTarget.version else {
                throw Abort(
                    .badRequest,
                    reason:
                        "No agent target version is configured, so an explicit artifact must state its targetVersion — the version the artifact's binary reports, which is what convergence is measured against."
                )
            }
            targetVersion = explicitVersion
            let override = ResolvedAgentArtifact(
                url: explicitURL,
                sha256: explicitDigest,
                kind: request.artifactKind ?? .tarball,
                tarballMember: request.tarballMember ?? AgentUpdateArtifacts.defaultTarballMember
            )
            artifactOverride = override
            artifactURL = override.url
        } else {
            guard let target = AgentVersionTarget.version else {
                throw Abort(
                    .badRequest,
                    reason:
                        "No agent target version is configured (dev build). Set AGENT_TARGET_VERSION, or pass artifactUrl and sha256 explicitly."
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
            artifactOverride = nil
            artifactURL = try await req.application.agentArtifactResolver.resolve(
                version: target,
                operatingSystem: os,
                architecture: architecture
            ).url
        }

        // An update is now convergence on a version, so "already there" is not
        // a caveat an operator can wave through: the agent no-ops a desired
        // version it already runs, and the assignment would hang until the
        // health budget called it failed. `force` no longer reinstalls — that
        // needs an edge-as-nonce the protocol does not carry (ADR 0001 stage 9).
        guard AgentVersionTarget.updateAvailable(agentVersion: agent.version, target: targetVersion) else {
            throw Abort(
                .conflict,
                reason:
                    "Agent already runs \(targetVersion). Updates converge on a version, so there is nothing to do — reinstalling the same build is no longer expressible (pass artifactUrl with a targetVersion the artifact's binary actually reports to move it somewhere else)."
            )
        }

        // The assignment *is* the update: durable on the row, re-read by every
        // sync assembly, and cleared by the auto-update sweep once the agent
        // re-registers at the target (or when the budget calls it failed).
        // Overwriting an in-flight assignment is deliberate — re-issuing the
        // update is the documented way to retry past a recorded failure.
        agent.updateDesiredVersion = targetVersion
        agent.updateAssignmentSource = .manual
        agent.updateArtifactOverride = artifactOverride
        agent.updateAttemptedAt = Date()
        agent.updateBlockedReason = nil
        agent.updateFailureReason = nil
        try await agent.save(on: req.db)

        req.logger.notice(
            "Agent update assigned",
            metadata: [
                "agentId": .string(agentId.uuidString),
                "agentName": .string(agent.name),
                "currentVersion": .string(agent.version),
                "targetVersion": .string(targetVersion),
                // Redacted: explicit overrides may be presigned URLs whose
                // query string is a credential.
                "artifactUrl": .string(DesiredAgentUpdate.redactURL(artifactURL)),
            ])

        // Push the sync now; the periodic timer is only the backstop.
        await req.agentService.syncDesiredState(agentId: agentId.uuidString)

        let response = Response(status: .accepted)
        try response.content.encode(
            AgentUpdateResponse(
                status: "assigned",
                targetVersion: targetVersion,
                artifactUrl: DesiredAgentUpdate.redactURL(artifactURL),
                message:
                    "Agent is converging on \(targetVersion): it downloads and verifies the artifact, then restarts and re-registers with the new version. Watch the agent's update status for progress."
            ))
        return response
    }

    // MARK: - Agent Properties

    struct AgentPatchRequest: Content {
        /// Enroll in (or withdraw from) declarative auto-update (issue #434).
        var autoUpdate: Bool?
    }

    /// Updates mutable agent properties. Currently only `autoUpdate`; scoped
    /// to `agent#manage` like the update action, since enrollment authorizes
    /// future restarts of this capacity.
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
            } else if agent.updateAssignmentSource != .manual {
                // Withdrawing clears the rollout's assignment: the next sync
                // stops carrying the desired update and the agent clears its
                // blocked status. An operator's own "update now" survives —
                // that path needs no enrollment in the first place, so
                // withdrawing from the fleet rollout must not cancel it.
                agent.clearUpdateAssignment()
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
