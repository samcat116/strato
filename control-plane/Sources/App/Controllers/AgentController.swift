import Fluent
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
    }

    // MARK: - Authorization

    /// Every agent-management operation is privileged: minting or reading a
    /// registration token lets the caller stand up a rogue agent (which receives
    /// VM-create dispatches, signed image URLs, and console traffic), and
    /// force-offlining agents can DoS the fleet. Restrict the entire controller to
    /// system admins. Defense in depth — do not rely on route-level middleware.
    private func requireSystemAdmin(_ req: Request) throws {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        guard user.isSystemAdmin else {
            throw Abort(.forbidden, reason: "System admin access required")
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

    private func requireSPIREDeprovisioningOrOverride(_ req: Request, action: String) async throws {
        guard await spireDeprovisioningUnavailable(req) else { return }
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
        let forwardedProto = req.headers["x-forwarded-proto"].first?.lowercased()
        let isHTTPS = forwardedProto == "https" || (forwardedProto == nil && req.url.scheme == "https")
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
        try requireSystemAdmin(req)

        let createRequest = try req.content.decode(CreateAgentRegistrationTokenRequest.self)
        try createRequest.validate()

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

        // Create new registration token
        let token = AgentRegistrationToken(
            agentName: createRequest.agentName,
            expirationHours: expirationHours
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
        try requireSystemAdmin(req)

        let tokens = try await AgentRegistrationToken.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()

        // Never echo the raw token (or a registration URL containing it) in a list
        // response — the plaintext value is shown exactly once, at creation time.
        return try tokens.map { try AgentRegistrationTokenListItem(from: $0) }
    }

    func revokeRegistrationToken(req: Request) async throws -> HTTPStatus {
        try requireSystemAdmin(req)

        guard let tokenId = req.parameters.get("tokenId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid token ID")
        }

        guard let token = try await AgentRegistrationToken.find(tokenId, on: req.db) else {
            throw Abort(.notFound, reason: "Registration token not found")
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
        // - An *expired* token's join token is equally expired (they share a
        //   lifetime), so its grant is inert — and because expired tokens can
        //   be superseded by a replacement for the same name, the entries that
        //   exist now may belong to the successor.
        //
        // Fail closed: if SPIRE is unreachable the token stays revocable later.
        let agentIsRegistered =
            try await Agent.query(on: req.db)
            .filter(\.$name == token.agentName)
            .first() != nil

        if token.isValid, !agentIsRegistered {
            try await requireSPIREDeprovisioningOrOverride(req, action: "registration token")
        }

        if token.isValid, !agentIsRegistered, let spire = req.application.spireRegistrationService {
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
        try requireSystemAdmin(req)

        let agents = try await Agent.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .all()

        // Update status based on heartbeat before returning
        for agent in agents {
            agent.updateStatusBasedOnHeartbeat()
        }

        try await agents.map { $0.save(on: req.db) }.flatten(on: req.eventLoop).get()

        return try agents.map { try AgentResponse(from: $0) }
    }

    func getAgent(req: Request) async throws -> AgentResponse {
        try requireSystemAdmin(req)

        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }

        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }

        agent.updateStatusBasedOnHeartbeat()
        try await agent.save(on: req.db)

        return try AgentResponse(from: agent)
    }

    func deregisterAgent(req: Request) async throws -> HTTPStatus {
        try requireSystemAdmin(req)

        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }

        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
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

        req.logger.info(
            "Deregistered agent",
            metadata: [
                "agentId": .string(agentId.uuidString),
                "agentName": .string(agent.name),
            ])

        return .noContent
    }

    func forceAgentOffline(req: Request) async throws -> HTTPStatus {
        try requireSystemAdmin(req)

        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }

        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }

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
}
