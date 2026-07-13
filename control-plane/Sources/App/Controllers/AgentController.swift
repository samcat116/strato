import Fluent
import StratoShared
import Vapor

struct AgentController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let agents = routes.grouped("api", "agents")

        // Agent registration token endpoints
        let tokenRoutes = agents.grouped("registration-tokens")
        tokenRoutes.post(use: createRegistrationToken)
        tokenRoutes.get(use: listRegistrationTokens)
        tokenRoutes.delete(":tokenId", use: revokeRegistrationToken)

        // Agent management endpoints
        agents.get(use: listAgents)
        agents.get(":agentId", use: getAgent)
        agents.delete(":agentId", use: deregisterAgent)
        agents.post(":agentId", "actions", "force-offline", use: forceAgentOffline)
        agents.post(":agentId", "actions", "update", use: updateAgent)
        // Scope reassignment corrects the migration backfill's oldest-org
        // guess on multi-org installs; deliberately system-admin only (it
        // moves dedicated capacity between tenants).
        agents.patch(":agentId", "organization", use: reassignOrganization)
    }

    // MARK: - Authorization

    /// Agent management is delegated to the owning organization: minting a
    /// registration token or force-offlining agents is scoped to the org/OU
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
        let user = try requireUser(req)
        guard user.isSystemAdmin else {
            throw Abort(.forbidden, reason: "System admin access required")
        }
    }

    /// System admin, or `manage_agents` on the given org/OU scope.
    private func requireManageAgents(_ req: Request, scope: OrganizationScope) async throws {
        let user = try requireUser(req)
        if user.isSystemAdmin { return }
        let ref = scope.spiceDBParentRef
        let allowed = try await req.spicedb.checkPermission(
            subject: user.id!.uuidString,
            permission: "manage_agents",
            resource: ref.subjectType,
            resourceId: ref.subjectId.uuidString
        )
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have permission to manage agents for this organization")
        }
    }

    /// System admin, or the given permission on the agent itself (resolved
    /// through `agent#parent` in SpiceDB).
    private func requireAgentPermission(_ req: Request, agent: Agent, permission: String) async throws {
        let user = try requireUser(req)
        if user.isSystemAdmin { return }
        let allowed = try await req.spicedb.checkPermission(
            subject: user.id!.uuidString,
            permission: permission,
            resource: "agent",
            resourceId: try agent.requireID().uuidString
        )
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have '\(permission)' permission on this agent")
        }
    }

    /// Until the scheduler and volume placement enforce org-scoped placement
    /// (phase 2 of the hierarchy overhaul), an agent may host VMs — and store
    /// volumes, which place on any online QEMU agent — whose projects belong
    /// to a different organization: cross-org placements from before scoping,
    /// or new ones the still-unscoped placement paths make. A delegated org
    /// admin must not be able to take down another tenant's workloads or
    /// strand its detached volumes, so destructive agent actions
    /// (force-offline, deregister) fall back to system-admin only while any
    /// foreign-org VM or volume lives here.
    private func requireNoForeignWorkloads(_ req: Request, agent: Agent) async throws {
        let user = try requireUser(req)
        if user.isSystemAdmin { return }

        let agentOrg = try await agent.rootOrganizationID(on: req.db)
        let agentIDString = try agent.requireID().uuidString

        let hostedVMs = try await VM.query(on: req.db)
            .filter(\.$hypervisorId == agentIDString)
            .with(\.$project)
            .all()
        for vm in hostedVMs {
            let vmOrg = try await vm.project.getRootOrganizationId(on: req.db)
            guard vmOrg == agentOrg else {
                throw Abort(
                    .forbidden,
                    reason:
                        "Agent hosts VMs belonging to another organization; only a system administrator can perform this action until they are migrated"
                )
            }
        }

        let storedVolumes = try await Volume.query(on: req.db)
            .filter(\.$hypervisorId == agentIDString)
            .with(\.$project)
            .all()
        for volume in storedVolumes {
            let volumeOrg = try await volume.project.getRootOrganizationId(on: req.db)
            guard volumeOrg == agentOrg else {
                throw Abort(
                    .forbidden,
                    reason:
                        "Agent stores volumes belonging to another organization; only a system administrator can perform this action until they are migrated"
                )
            }
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
    /// exists (a `spireProvisioned` token): the guard then applies whenever
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

    // MARK: - Registration Token Management

    /// Base WebSocket URL agents should dial, embedded in registration URLs.
    ///
    /// The Host header only names whatever hop the request came in on — behind
    /// an ingress or port-forward that can be an address hypervisor hosts
    /// cannot reach, so an explicitly configured EXTERNAL_HOSTNAME wins. The
    /// scheme likewise can't come from req.url.scheme alone: behind a
    /// TLS-terminating proxy the local hop is plain HTTP, so trust
    /// X-Forwarded-Proto when present.
    private func webSocketBaseURL(req: Request) -> String {
        // When SPIRE provisioning is active, agents connect to the Envoy mTLS
        // listener (EXTERNAL_HOSTNAME), which is always TLS regardless of the
        // browser-facing scheme — so the agent URL must be wss:// even for an
        // http:// (localhost) origin. Otherwise trust X-Forwarded-Proto (the
        // local hop behind a TLS terminator is plain HTTP).
        let spireProvisioned = req.application.spireRegistrationService != nil
        let forwardedProto = req.headers["x-forwarded-proto"].first?.lowercased()
        let isHTTPS =
            spireProvisioned || forwardedProto == "https" || (forwardedProto == nil && req.url.scheme == "https")
        let scheme = isHTTPS ? "wss" : "ws"

        let host =
            Environment.get("EXTERNAL_HOSTNAME").map(Self.sanitizedHost)
            ?? req.headers["host"].first
            ?? "localhost:8080"

        return "\(scheme)://\(host)"
    }

    /// Reduces an EXTERNAL_HOSTNAME value to bare host[:port]. Operators
    /// naturally set a full URL ("https://cp.example.com/") here; prepending
    /// a scheme to that verbatim would emit "ws://https://…", which the agent
    /// then rejects as an invalid registration URL.
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

    func createRegistrationToken(req: Request) async throws -> AgentRegistrationTokenResponse {
        let createRequest = try req.content.decode(CreateAgentRegistrationTokenRequest.self)
        try createRequest.validate()

        // Resolve and authorize the owning scope before anything else: the
        // token's org is what the redeeming agent becomes dedicated to.
        let scope = try createRequest.organizationScope()
        try await scope.validateExists(on: req.db)
        try await requireManageAgents(req, scope: scope)

        // Check if agent name is already in use by an existing agent
        let existingAgent = try await Agent.query(on: req.db)
            .filter(\.$name == createRequest.agentName)
            .first()

        if existingAgent != nil {
            throw Abort(.conflict, reason: "Agent name '\(createRequest.agentName)' is already registered")
        }

        // Check if there's already an unused token for this agent name
        let existingToken = try await AgentRegistrationToken.query(on: req.db)
            .filter(\.$agentName == createRequest.agentName)
            .filter(\.$isUsed == false)
            .first()

        if let existing = existingToken, existing.isValid {
            throw Abort(
                .conflict, reason: "A valid registration token already exists for agent '\(createRequest.agentName)'")
        }

        let expirationHours = createRequest.expirationHours ?? 1

        // Resolve the target site up front so a typo'd id fails the request
        // instead of silently minting a site-less token — and require it to
        // belong to the token's organization: a site is one OVN deployment
        // owned by one org, so a foreign agent joining it would mix tenants
        // on a shared SDN. The caller also needs manage on the site itself
        // (not just manage_agents on the token's scope): with agents and
        // sites delegated to different OUs of one org, a token-carried site
        // pin must not admit an agent into a sibling OU's fabric that the
        // site membership endpoint would refuse.
        if let siteId = createRequest.siteId {
            guard let site = try await Site.find(siteId, on: req.db) else {
                throw Abort(.badRequest, reason: "Site \(siteId) does not exist")
            }
            guard let siteScope = site.organizationScope,
                try await siteScope.contains(scope, on: req.db)
            else {
                throw Abort(
                    .badRequest,
                    reason: "Site \(siteId)'s organization scope does not contain the token's")
            }
            let user = try requireUser(req)
            if !user.isSystemAdmin {
                let allowed = try await req.spicedb.checkPermission(
                    subject: user.id!.uuidString,
                    permission: "manage",
                    resource: "site",
                    resourceId: siteId.uuidString
                )
                guard allowed else {
                    throw Abort(.forbidden, reason: "You don't have 'manage' permission on site \(siteId)")
                }
            }
        }

        // Provision the node in SPIRE first (join token + workload entry).
        // SPIRE is not transactional with our database, so order matters: if
        // provisioning fails nothing was persisted here, and if the save below
        // fails the provisioning is rolled back best-effort (a leftover entry
        // is reused on retry; the unredeemed join token just expires). The
        // join token shares the WS token's lifetime — one provisioning window.
        var spireProvisioning: SPIREAgentProvisioning?
        if let spire = req.application.spireRegistrationService {
            do {
                spireProvisioning = try await spire.provisionAgent(
                    named: createRequest.agentName,
                    joinTokenTTLSeconds: Int32(expirationHours * 3600)
                )
            } catch let error as SPIRERegistrationError {
                throw Abort(.badRequest, reason: error.localizedDescription)
            } catch {
                req.logger.error(
                    "SPIRE provisioning failed while creating registration token",
                    metadata: [
                        "agentName": .string(createRequest.agentName),
                        "error": .string("\(error)"),
                    ])
                throw Abort(
                    .badGateway,
                    reason:
                        "SPIRE provisioning failed; no registration token was created. \(error.localizedDescription)"
                )
            }
        }

        // Create new registration token, recording whether it carries a SPIRE
        // grant — revocation decides ownership from this fact, not from
        // whatever the process configuration happens to be at revoke time.
        let token = AgentRegistrationToken(
            agentName: createRequest.agentName,
            expirationHours: expirationHours,
            spireProvisioned: spireProvisioning != nil,
            siteID: createRequest.siteId,
            organizationScope: scope
        )

        do {
            try await token.save(on: req.db)
        } catch {
            if let spire = req.application.spireRegistrationService, spireProvisioning != nil {
                await spire.rollbackProvisioning(agentName: createRequest.agentName)
            }
            throw error
        }

        let baseURL = webSocketBaseURL(req: req)

        req.logger.info(
            "Created agent registration token",
            metadata: [
                "agentName": .string(createRequest.agentName),
                "tokenId": .string(token.id?.uuidString ?? "unknown"),
                "expiresAt": .string(token.expiresAt?.description ?? "no expiration"),
                "spireProvisioned": .string(spireProvisioning == nil ? "no" : "yes"),
            ])

        return try AgentRegistrationTokenResponse(from: token, baseURL: baseURL, spire: spireProvisioning)
    }

    func listRegistrationTokens(req: Request) async throws -> [AgentRegistrationTokenListItem] {
        let user = try requireUser(req)

        let tokens = try await AgentRegistrationToken.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()

        // System admins see everything; org admins see the tokens scoped to
        // orgs/OUs they hold manage_agents on. Scopeless tokens (rotated
        // reconnect credentials, pre-scoping rows) stay system-admin only.
        let visible: [AgentRegistrationToken]
        if user.isSystemAdmin {
            visible = tokens
        } else {
            var allowed: [AgentRegistrationToken] = []
            for token in tokens {
                guard let ref = token.organizationScope?.spiceDBParentRef else { continue }
                let ok = try await req.spicedb.checkPermission(
                    subject: user.id!.uuidString,
                    permission: "manage_agents",
                    resource: ref.subjectType,
                    resourceId: ref.subjectId.uuidString
                )
                if ok { allowed.append(token) }
            }
            visible = allowed
        }

        // Never echo the raw token (or a registration URL containing it) in a list
        // response — the plaintext value is shown exactly once, at creation time.
        return try visible.map { try AgentRegistrationTokenListItem(from: $0) }
    }

    func revokeRegistrationToken(req: Request) async throws -> HTTPStatus {
        guard let tokenId = req.parameters.get("tokenId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid token ID")
        }

        guard let token = try await AgentRegistrationToken.find(tokenId, on: req.db) else {
            throw Abort(.notFound, reason: "Registration token not found")
        }

        if let scope = token.organizationScope {
            try await requireManageAgents(req, scope: scope)
        } else {
            // Scopeless tokens (rotated reconnect credentials) have no org to
            // delegate to; revoking one severs a live agent's reconnect path.
            try requireSystemAdmin(req)
        }

        // Revoking a token withdraws the whole provisioning grant — including
        // the SPIRE entries created alongside it — but only when this token
        // still *owns* that grant:
        //
        // - A *used* token belongs to an agent that registered via token auth;
        //   its entries are removed by deregistering the agent instead.
        // - An existing Agent row with this name means the node registered over
        //   mTLS, which never redeems the WebSocket token: the token looks
        //   unused, but the SPIRE entries now belong to a live agent.
        // - A *valid unused SPIRE-provisioned successor* token for the same
        //   name means the grant was reissued; the entries (and the stable
        //   node identity a current bootstrap may already have attested with)
        //   belong to the successor, so touching SPIRE here would sabotage it.
        //   A successor minted while the registration API was unconfigured
        //   carries no grant and does not take ownership.
        //
        // Expiry alone does NOT make a grant inert: the join token may have
        // been redeemed before it expired (spire-agent attests first; the
        // Agent row only appears once strato-agent registers), leaving entries
        // and an attested node that can still mint SVIDs. An expired token
        // with no successor therefore still owns — and must revoke — its grant.
        //
        // Fail closed: if SPIRE is unreachable the token stays revocable later.
        let agentIsRegistered =
            try await Agent.query(on: req.db)
            .filter(\.$name == token.agentName)
            .first() != nil

        let provisionedSuccessorExists = try await AgentRegistrationToken.query(on: req.db)
            .filter(\.$agentName == token.agentName)
            .filter(\.$isUsed == false)
            .filter(\.$spireProvisioned == true)
            .filter(\.$id != token.requireID())
            .all()
            .contains { $0.isValid }

        let tokenOwnsGrant =
            token.spireProvisioned && !token.isUsed && !agentIsRegistered && !provisionedSuccessorExists

        if tokenOwnsGrant {
            try await requireSPIREDeprovisioningOrOverride(req, action: "registration token", grantKnown: true)
        }

        if tokenOwnsGrant, let spire = req.application.spireRegistrationService {
            do {
                try await spire.deprovisionAgent(named: token.agentName)
            } catch {
                req.logger.error(
                    "SPIRE deprovisioning failed while revoking registration token",
                    metadata: [
                        "agentName": .string(token.agentName),
                        "error": .string("\(error)"),
                    ])
                throw Abort(
                    .badGateway,
                    reason:
                        "SPIRE deprovisioning failed; the registration token was not revoked. Retry when the SPIRE server is reachable."
                )
            }
        }

        try await token.delete(on: req.db)

        req.logger.info(
            "Revoked agent registration token",
            metadata: [
                "tokenId": .string(tokenId.uuidString),
                "agentName": .string(token.agentName),
            ])

        return .noContent
    }

    // MARK: - Agent Management

    func listAgents(req: Request) async throws -> [AgentResponse] {
        let user = try requireUser(req)

        let agents = try await Agent.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()

        // System admins see the whole fleet; everyone else sees the agents
        // they can view through agent#parent (their orgs'/OUs' capacity).
        let visible: [Agent]
        if user.isSystemAdmin {
            visible = agents
        } else {
            var allowed: [Agent] = []
            for agent in agents {
                guard let agentId = agent.id else { continue }
                let ok = try await req.spicedb.checkPermission(
                    subject: user.id!.uuidString,
                    permission: "view",
                    resource: "agent",
                    resourceId: agentId.uuidString
                )
                if ok { allowed.append(agent) }
            }
            visible = allowed
        }

        // Update status based on heartbeat before returning
        for agent in visible {
            agent.updateStatusBasedOnHeartbeat()
        }

        try await visible.map { $0.save(on: req.db) }.flatten(on: req.eventLoop).get()

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
        try await requireNoForeignWorkloads(req, agent: agent)

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
        await req.agentService.forceUnregisterAgent(agent.name)

        // Delete from database
        try await agent.delete(on: req.db)

        // Drop the ownership tuple; a leftover would re-grant access if the
        // UUID were ever reused. Best-effort — a failure leaves a tuple for a
        // row that no longer exists, which grants nothing by itself.
        if let ref = agent.organizationScope?.spiceDBParentRef {
            try? await req.spicedb.deleteRelationship(
                entity: "agent", entityId: agentId.uuidString,
                relation: "parent",
                subject: ref.subjectType, subjectId: ref.subjectId.uuidString)
        }

        // Deregistration severs the agent's credentials: delete its unused
        // tokens (the rotated reconnect credential in particular). Left
        // behind, the scopeless reconnect token would be revocable only by a
        // system admin yet block minting a new token for this agent name via
        // the duplicate-token guard — locking the name for up to 30 days.
        // SPIRE entries for the name were already deprovisioned above, so
        // these rows carry no external grant.
        try await AgentRegistrationToken.query(on: req.db)
            .filter(\.$agentName == agent.name)
            .filter(\.$isUsed == false)
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
        try await requireNoForeignWorkloads(req, agent: agent)

        // Force agent offline in in-memory registry
        await req.agentService.forceUnregisterAgent(agent.name)

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
        /// hosted Firecracker VMs (not re-adopted after restart) and an agent
        /// already at the target version.
        var force: Bool?
        /// Explicit artifact override for deployments the URL-convention
        /// resolver can't serve (air-gapped without a mirror, main-branch
        /// builds, one-off testing). Requires `sha256`.
        var artifactUrl: String?
        /// Hex SHA-256 of the artifact at `artifactUrl`.
        var sha256: String?
        /// Version label for an explicit artifact (informational; shown in
        /// logs and the response). Defaults to the configured target.
        var targetVersion: String?
    }

    struct AgentUpdateResponse: Content {
        let status: String
        let targetVersion: String
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

        try await requireAgentPermission(req, agent: agent, permission: "manage")
        // Restarting the agent orphans any hosted Firecracker VMs, so this is
        // destructive enough to fall under the same cross-tenant guard as
        // force-offline/deregister.
        try await requireNoForeignWorkloads(req, agent: agent)

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

        // QEMU VMs survive an agent restart (re-adopted via their deterministic
        // QMP sockets), but Firecracker VMs are not re-adopted — they keep
        // running as orphans that can only be deleted. Make the operator
        // acknowledge that explicitly.
        if !force {
            let firecrackerVMs = try await VM.query(on: req.db)
                .filter(\.$hypervisorId == agentId.uuidString)
                .filter(\.$hypervisorType == .firecracker)
                .count()
            guard firecrackerVMs == 0 else {
                throw Abort(
                    .conflict,
                    reason:
                        "Agent hosts \(firecrackerVMs) Firecracker VM(s), which are not re-adopted after an agent restart. Delete or migrate them, or pass force to proceed anyway."
                )
            }
        }

        let targetVersion: String
        let artifact: ResolvedAgentArtifact
        if let explicitURL = request.artifactUrl {
            guard let explicitDigest = request.sha256.flatMap({ AgentUpdateArtifacts.parseChecksum($0) })
            else {
                throw Abort(.badRequest, reason: "artifactUrl requires a hex SHA-256 digest in sha256")
            }
            targetVersion = request.targetVersion ?? AgentVersionTarget.version ?? "unspecified"
            artifact = ResolvedAgentArtifact(
                url: explicitURL,
                sha256: explicitDigest,
                tarballMember: AgentUpdateArtifacts.defaultTarballMember
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
            artifact = try await AgentUpdateArtifacts.resolveArtifact(
                targetVersion: target,
                operatingSystem: os,
                architecture: architecture,
                client: req.client,
                logger: req.logger
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
                "artifactUrl": .string(artifactURL),
            ])

        let message = AgentUpdateMessage(
            targetVersion: targetVersion,
            artifactURL: artifact.url,
            sha256: artifact.sha256,
            artifactKind: .tarball,
            tarballMember: artifact.tarballMember
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
                artifactUrl: artifactURL,
                message:
                    "Agent verified and installed the new binary and is restarting; it will re-register as \(targetVersion)."
            )
        case .error(let error, let details):
            throw Abort(
                .badGateway,
                reason: details.map { "\(error): \($0)" } ?? error)
        }
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
        let ref = scope.spiceDBParentRef
        let parentTuple = RelationshipTuple(
            entity: "agent",
            entityId: agentId.uuidString,
            relation: "parent",
            subject: ref.subjectType,
            subjectId: ref.subjectId.uuidString
        )

        if scope == previousScope {
            // Re-touch the tuple so retrying after a partial failure below
            // (DB committed, tuple write lost) converges instead of no-oping.
            try await req.spicedb.touchRelationships([parentTuple])
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

        // SpiceDB first, DB last: both tuple operations are idempotent
        // (touch, and delete-if-present), so a failure at any step leaves the
        // request retryable — whereas committing the DB first would make a
        // retry short-circuit on the no-op path above with the tuples still
        // pointing at the old org.
        try await req.spicedb.touchRelationships([parentTuple])
        if let oldRef = previousScope?.spiceDBParentRef {
            try await req.spicedb.deleteRelationship(
                entity: "agent", entityId: agentId.uuidString,
                relation: "parent",
                subject: oldRef.subjectType, subjectId: oldRef.subjectId.uuidString)
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
