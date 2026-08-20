import ControlPlanePostgres
import Fluent
import StratoShared
import Vapor

struct AgentController: RouteCollection {
    private let enrollments: AgentEnrollmentsPersistence?
    private let agents: AgentsPersistence?
    private let workloads: WorkloadsPersistence?
    private let hierarchy: HierarchyPersistence?

    init(
        enrollments: AgentEnrollmentsPersistence? = nil,
        agents: AgentsPersistence? = nil,
        workloads: WorkloadsPersistence? = nil,
        hierarchy: HierarchyPersistence? = nil
    ) {
        self.enrollments = enrollments
        self.agents = agents
        self.workloads = workloads
        self.hierarchy = hierarchy
    }

    func boot(routes: RoutesBuilder) throws {
        let agents = routes.grouped("api", "agents")

        // Agent enrollment endpoints (SPIRE node provisioning). Deliberately a
        // sibling collection rather than `/api/agents/enrollments`: an
        // enrollment is its own resource with its own lifecycle, and nesting it
        // would put the constant `enrollments` in the slot that otherwise holds
        // an agent id, producing ambiguous path templates (issue #595).
        let enrollmentRoutes = routes.grouped("api", "agent-enrollments")
        enrollmentRoutes.get("install", use: installAgent)
        enrollmentRoutes.post("bootstrap", use: redeemEnrollment)
        enrollmentRoutes.post(use: createEnrollment)
        enrollmentRoutes.get(use: listEnrollments)
        enrollmentRoutes.delete(":enrollmentId", use: revokeEnrollment)

        // Agent management endpoints
        agents.get(use: listAgents)
        agents.get(":agentId", use: getAgent)
        agents.delete(":agentId", use: deregisterAgent)
        agents.post(":agentId", "actions", "force-offline", use: forceAgentOffline)
        agents.post(":agentId", "actions", "update", use: updateAgent)
        // Withdraws an update assignment. The only way back from an update that
        // can never converge, since the agent it was assigned to is usually the
        // reason it can't.
        agents.delete(":agentId", "actions", "update", use: cancelAgentUpdate)
        // Finishes a node's re-identification (STR-98): moves the workloads it
        // is demonstrably running off the agent record it was enrolled under
        // before.
        agents.post(":agentId", "actions", "adopt-workloads", use: adoptWorkloads)
        agents.patch(":agentId", use: patchAgent)
    }

    // MARK: - Authorization
    //
    // Agent management is delegated to the owning organization: enrolling a
    // node or force-offlining agents is scoped to the org/OU whose capacity it
    // is (`manage_agents`), and system admins retain unconditional access.
    // Defense in depth — do not rely on route-level middleware.

    private func requireSystemAdmin(_ req: Request) async throws {
        // The decision-marking gate, so admin-only mutations (scopeless
        // enrollments, org reassignment) satisfy the middleware's
        // handler-evaluated assertion.
        _ = try await req.requireSystemAdmin()
    }

    /// `agent:manage` on the given org/OU scope (system admins pass through
    /// the evaluator's tier-1 policy).
    private func requireManageAgents(_ req: Request, scope: OrganizationScope) async throws {
        let allowed = try await req.can("agent:manage", on: scope.checkNode)
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have permission to manage agents for this organization")
        }
    }

    private func requireAgentAction(
        _ action: String,
        agent: AgentSnapshot,
        req: Request
    ) async throws {
        guard agent.organizationID != nil || agent.organizationalUnitID != nil else {
            _ = try await req.requireSystemAdmin("This agent has no owning organization")
            return
        }
        guard try await req.can(action, on: IAMNode(type: .agent, id: agent.id)) else {
            throw Abort(.forbidden, reason: "You don't have '\(action)' access on this agent")
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
        _ req: Request,
        registry: OrgSPIREClientRegistry,
        trustDomain: String,
        action: String,
        on db: any Database
    ) async throws -> SPIRERegistrationService? {
        if let service = try await registry.service(forTrustDomain: trustDomain, on: db) {
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
            req.controlPlaneConfiguration.string(.externalHostname).map(Self.sanitizedHost)
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

    /// GET /api/agent-enrollments/install
    ///
    /// A tiny public wrapper rather than a second copy of the real installer.
    /// Its URL fixes the control-plane origin, so the operator only passes the
    /// opaque token and the token itself carries no network or identity facts.
    func installAgent(req: Request) async throws -> Response {
        let bootstrapURL =
            "\(OAuthController.publicOrigin(configuration: req.controlPlaneConfiguration))"
            + "/api/agent-enrollments/bootstrap"
        let installerURL = try Self.installerURL(
            gitSHA: BuildInfo.gitSHA(configuration: req.controlPlaneConfiguration))
        let script = Self.installerScript(
            bootstrapURL: bootstrapURL, installerURL: installerURL)

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/x-shellscript; charset=utf-8")
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return Response(status: .ok, headers: headers, body: .init(string: script + "\n"))
    }

    static func installerURL(gitSHA: String) throws -> String {
        guard gitSHA.count == 40, gitSHA.allSatisfy(\.isHexDigit) else {
            throw Abort(
                .serviceUnavailable,
                reason: "STRATO_GIT_SHA must identify the deployed control-plane revision")
        }
        return "https://raw.githubusercontent.com/samcat116/strato/\(gitSHA)/deploy/agent/install.sh"
    }

    static func installerScript(bootstrapURL: String, installerURL: String) -> String {
        let encodedBootstrapURL = Data(bootstrapURL.utf8).base64EncodedString()
        return """
            #!/bin/sh
            set -eu

            if [ "$#" -lt 1 ]; then
              echo "usage: curl -fsSL <strato-origin>/api/agent-enrollments/install | sudo bash -s -- <enrollment-token> [installer-options...]" >&2
              exit 2
            fi

            token=$1
            shift
            case "$token" in
              enroll_v1_*) ;;
              *) echo "invalid Strato enrollment token" >&2; exit 2 ;;
            esac

            installer=$(mktemp /tmp/strato-agent-install.XXXXXX)
            trap 'rm -f "$installer"' EXIT HUP INT TERM
            curl -fsSL "\(installerURL)" -o "$installer"
            bootstrap_url=$(printf '%s' '\(encodedBootstrapURL)' | base64 --decode)
            bash "$installer" --enrollment-token "$token" --enrollment-api-url "$bootstrap_url" "$@"
            """
    }

    /// POST /api/agent-enrollments/bootstrap
    ///
    /// Redeem the short-lived enrollment bearer once for server-selected
    /// configuration and a just-in-time SPIRE join token. The database claim
    /// happens before the external mint, so concurrent replays cannot obtain
    /// independent credentials for the same node. The installer persists the
    /// winning response locally for same-host recovery.
    func redeemEnrollment(req: Request) async throws -> Response {
        guard let enrollments, let bearer = req.headers.bearerAuthorization,
            bearer.token.hasPrefix("enroll_v1_")
        else {
            throw Abort(.unauthorized, reason: "Enrollment token is invalid, expired, or already used")
        }

        do {
            return try await enrollments.redeemBootstrapToken(
                tokenHash: AgentEnrollment.hashBootstrapToken(bearer.token),
                prepare: { lockedEnrollment in
                    guard let registry = OrgSPIREClientRegistry.fromApplication(req.application) else {
                        throw Abort(.serviceUnavailable, reason: "Agent enrollment requires SPIRE")
                    }
                    guard
                        let selection = try await registry.bootstrapSelection(
                            forTrustDomain: lockedEnrollment.trustDomain, on: req.db)
                    else {
                        throw Abort(
                            .serviceUnavailable,
                            reason: "The SPIRE instance for this enrollment is no longer available")
                    }
                    return selection
                },
                operation: { lockedEnrollment, selection in
                    let expiresAt = lockedEnrollment.expiresAt
                    let enrollmentID = lockedEnrollment.id
                    let remainingSeconds = max(1, Int(expiresAt.timeIntervalSinceNow.rounded(.down)))
                    let ttlSeconds = Int32(min(remainingSeconds, Int(Int32.max)))
                    let joinToken: SPIREAgentJoinToken
                    do {
                        joinToken = try await selection.service.mintAgentJoinToken(
                            named: lockedEnrollment.agentName, ttlSeconds: ttlSeconds)
                    } catch {
                        req.logger.error(
                            "SPIRE join-token minting failed while redeeming an agent enrollment",
                            metadata: [
                                "agentName": .string(lockedEnrollment.agentName),
                                "enrollmentId": .string(enrollmentID.uuidString),
                                "error": .string("\(error)"),
                            ])
                        throw Abort(
                            .badGateway,
                            reason:
                                "SPIRE could not issue the node attestation token. The one-time enrollment token was consumed; revoke and recreate the enrollment."
                        )
                    }

                    let bundle = AgentBootstrapBundle(
                        controlPlaneURL: "\(webSocketBaseURL(req: req))/agent/ws",
                        agentName: lockedEnrollment.agentName,
                        joinToken: joinToken.value,
                        spireServerAddress: selection.service.registrationConfig.serverPublicAddress,
                        trustDomain: lockedEnrollment.trustDomain,
                        controlPlaneSPIFFEID: selection.controlPlaneSPIFFEID
                    )
                    var headers = HTTPHeaders()
                    headers.replaceOrAdd(name: .contentType, value: AgentBootstrapBundle.mediaType)
                    headers.replaceOrAdd(name: .cacheControl, value: "no-store")
                    return Response(status: .ok, headers: headers, body: .init(string: bundle.serialized()))
                }
            )
        } catch AgentEnrollmentPersistenceError.invalidBootstrapToken {
            throw Abort(.unauthorized, reason: "Enrollment token is invalid, expired, or already used")
        }
    }

    func createEnrollment(req: Request) async throws -> AgentEnrollmentResponse {
        guard let enrollments else {
            throw Abort(.internalServerError, reason: "Agent enrollment persistence is unavailable")
        }
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
        let existingAgent = try await LegacyAgentStore.agents(
            trustDomain: trustDomain, name: createRequest.agentName, on: req.db
        ).first

        if existingAgent != nil {
            throw Abort(.conflict, reason: "Agent name '\(createRequest.agentName)' is already registered")
        }

        // One enrollment per name per trust domain (the pair is unique).
        // Re-enrolling a node means revoking the old one first, so its SPIRE
        // grant is withdrawn rather than orphaned alongside a second grant for
        // the same identity.
        if try await enrollments.exists(
            trustDomain: trustDomain,
            agentName: createRequest.agentName
        ) {
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
        guard let site = try await LegacySiteStore.site(id: siteId, on: req.db) else {
            throw Abort(.badRequest, reason: "Site \(siteId) does not exist")
        }
        guard let siteScope = site.organizationScope,
            try await siteScope.contains(scope, on: req.db)
        else {
            throw Abort(
                .badRequest,
                reason: "Site \(siteId)'s organization scope does not contain the enrollment's")
        }
        let siteAllowed = try await req.can("site:manage", on: IAMNode(type: .site, id: siteId))
        guard siteAllowed else {
            throw Abort(.forbidden, reason: "You don't have 'manage' permission on site \(siteId)")
        }

        // Prepare the node's durable workload grant in SPIRE first. The
        // one-time node-attestation token is deliberately minted later, when a
        // host presents the enrollment's bootstrap token.
        // SPIRE is not transactional with our database, so order matters: if
        // provisioning fails nothing was persisted here, and if the save below
        // fails the prepared entry is rolled back best-effort. A leftover entry
        // is safe and reused on retry; no join token exists at this point.
        let provisioning: SPIREAgentConfiguration
        do {
            provisioning = try await spire.prepareAgent(
                named: createRequest.agentName,
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

        let bootstrapToken = AgentEnrollment.generateBootstrapToken()

        let enrollmentWrite = AgentEnrollmentWrite(
            agentName: createRequest.agentName,
            trustDomain: provisioning.trustDomain,
            spiffeID: provisioning.spiffeID,
            bootstrapTokenHash: AgentEnrollment.hashBootstrapToken(bootstrapToken),
            siteID: createRequest.siteId,
            organizationID: scope.organizationID,
            organizationalUnitID: scope.organizationalUnitID,
            expiresAt: Date().addingTimeInterval(TimeInterval(expirationHours * 3600))
        )

        let enrollment: AgentEnrollmentSnapshot
        do {
            enrollment = try await enrollments.create(enrollmentWrite)
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
                (try? await enrollments.exists(
                    trustDomain: trustDomain,
                    agentName: createRequest.agentName
                )) == true

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
                "enrollmentId": .string(enrollment.id.uuidString),
                "spiffeId": .string(enrollment.spiffeID),
                "expiresAt": .string(enrollment.expiresAt.description),
            ])

        return try AgentEnrollmentResponse(
            from: enrollment,
            publicOrigin: OAuthController.publicOrigin(configuration: req.controlPlaneConfiguration),
            bootstrapToken: bootstrapToken,
            spire: provisioning
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
        guard let enrollments else {
            throw Abort(.internalServerError, reason: "Agent enrollment persistence is unavailable")
        }
        _ = try req.auth.require(User.self)
        let orgFilter = try await OrganizationAccessService.organizationListFilter(on: req)

        let enrollmentRows = try await enrollments.list(
            filter: orgFilter.map {
                AgentEnrollmentListFilter(
                    organizationID: $0.organizationID,
                    organizationalUnitIDs: $0.organizationalUnitIDs
                )
            }
        )

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
        //
        // This is the one list in the app whose *read* is gated on a write-shaped
        // action, which STR-115 gave a consequence: `agent:manage` is not a read,
        // so a read-restricted credential now matches no row and gets an empty
        // page rather than a 403 — indistinguishable from "no enrollments". It is
        // called out in `docs/architecture/iam.md` alongside the other
        // tightenings. Gating the listing on a read-shaped action instead would
        // fix the shape but widen who may see enrollments, which is a binding
        // question and not this issue's to answer.
        let manageable = try await req.canFilter(
            "agent:manage", on: enrollmentRows.compactMap { $0.organizationScope?.checkNode })
        let visible = enrollmentRows.filter { enrollment in
            guard let scope = enrollment.organizationScope else {
                return req.allowsScopelessPlatformRow(action: "agent:manage")
            }
            return manageable.contains(scope.checkNode)
        }

        // Never echo the bootstrap token in a list response — it is shown
        // exactly once, at creation time. SPIRE join tokens are not persisted.
        return try visible.map { try AgentEnrollmentListItem(from: $0) }
    }

    func revokeEnrollment(req: Request) async throws -> HTTPStatus {
        guard let enrollments else {
            throw Abort(.internalServerError, reason: "Agent enrollment persistence is unavailable")
        }
        guard let enrollmentId = req.parameters.get("enrollmentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid enrollment ID")
        }

        guard let enrollment = try await enrollments.find(id: enrollmentId) else {
            throw Abort(.notFound, reason: "Agent enrollment not found")
        }

        if let scope = enrollment.organizationScope {
            try await requireManageAgents(req, scope: scope)
        } else {
            // Scopeless rows have no org to delegate revocation to.
            try await requireSystemAdmin(req)
        }

        let agentName: String
        do {
            agentName = try await enrollments.revoke(id: enrollmentId) {
                enrollment, enrollmentOwnsGrant in
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
                        req,
                        registry: registry,
                        trustDomain: enrollment.trustDomain,
                        action: "agent enrollment",
                        on: req.db)
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

                if enrollmentOwnsGrant {
                    // No agent row exists, so any workload-registry row for the
                    // identity is an orphan of the just-revoked SPIRE grant (#491).
                    try await WorkloadRegistry.deregisterAgent(
                        identity: AgentIdentity(trustDomain: enrollment.trustDomain, name: enrollment.agentName),
                        on: req.db)
                }
                return enrollment.agentName
            }
        } catch AgentEnrollmentPersistenceError.notFound {
            throw Abort(.notFound, reason: "Agent enrollment not found")
        }

        req.logger.info(
            "Revoked agent enrollment",
            metadata: [
                "enrollmentId": .string(enrollmentId.uuidString),
                "agentName": .string(agentName),
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
        guard let agentsPersistence = agents, let hierarchy else {
            throw Abort(.internalServerError, reason: "Native agent persistence is unavailable")
        }
        let orgFilter = try await OrganizationAccessService.organizationListFilter(
            on: req,
            using: hierarchy
        )
        let agentRows: [AgentSnapshot]
        if let orgFilter {
            agentRows = try await agentsPersistence.agents(
                organizationID: orgFilter.organizationID,
                organizationalUnitIDs: orgFilter.organizationalUnitIDs
            )
        } else {
            agentRows = try await agentsPersistence.allAgents()
        }

        // Everyone is filtered the same way: `view` on the agent, resolved
        // through agent#parent (their orgs'/OUs' capacity). An admin's
        // fleet-wide view comes from the tier-1 `platform-system-admin` policy
        // inside the evaluator, so it is logged and a guardrail can narrow it.
        // A pre-scoping agent has no ancestor chain to evaluate against and
        // stays system-admin only, as in `requireAgentAction`. An
        // organization_id filter narrows the query first — see listSites.
        // The scoped rows are decided in one batch (#687); a scopeless row has
        // no node to batch and is answered without the evaluator.
        let readable = try await req.canFilter(
            "agent:read",
            on: agentRows.compactMap { agent in
                guard agent.organizationID != nil || agent.organizationalUnitID != nil else {
                    return nil
                }
                return IAMNode(type: .agent, id: agent.id)
            })
        var visible: [AgentSnapshot] = []
        for agent in agentRows {
            guard agent.organizationID != nil || agent.organizationalUnitID != nil else {
                if req.allowsScopelessPlatformRow(action: "agent:read") { visible.append(agent) }
                continue
            }
            if readable.contains(IAMNode(type: .agent, id: agent.id)) { visible.append(agent) }
        }

        let targetVersion = AgentVersionTarget.version(
            configuration: req.controlPlaneConfiguration)
        return try visible.map { try AgentResponse(from: $0, targetVersion: targetVersion) }
    }

    func getAgent(req: Request) async throws -> AgentResponse {
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }

        guard let agents, let workloads else {
            throw Abort(.internalServerError, reason: "Native agent persistence is unavailable")
        }
        guard let agent = try await agents.agent(id: agentId) else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        if agent.organizationID == nil && agent.organizationalUnitID == nil {
            _ = try await req.requireSystemAdmin("This agent has no owning organization")
        } else {
            guard try await req.can("agent:read", on: IAMNode(type: .agent, id: agentId)) else {
                throw Abort(.forbidden, reason: "You don't have 'agent:read' access on this agent")
            }
        }

        // Workloads this agent holds that the control plane refused to
        // authorize tearing down (STR-98). Only on the detail view: the list
        // endpoint shouldn't pay for a claim query per agent, and this is
        // something an operator investigates one host at a time.
        let held = try await workloads.heldClaims(agentID: agentId)
            .map(AgentResponse.HeldWorkloadSummary.init(from:))

        return try AgentResponse(
            from: agent,
            targetVersion: AgentVersionTarget.version(configuration: req.controlPlaneConfiguration),
            heldWorkloads: held)
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
        guard let workloads else {
            throw Abort(.internalServerError, reason: "Native workload persistence is unavailable")
        }
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }
        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        try await req.requireAgentAction("agent:manage", on: agent)

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
        try await req.requireAgentAction("agent:manage", on: sourceAgent)
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

        // Claim evidence, VM/sandbox placement, volume replicas, and claim
        // consumption commit together in the native module.
        let adopted: WorkloadAdoptionResult
        do {
            adopted = try await workloads.adoptWorkloads(
                targetAgentID: targetId, sourceAgentID: sourceId)
        } catch WorkloadsPersistenceError.noMatchingClaims {
            throw Abort(
                .conflict,
                reason: "This agent does not report holding any workloads placed on that agent record")
        }
        let counts = AdoptWorkloadsResponse(
            adoptedVMs: adopted.adoptedVMs,
            adoptedSandboxes: adopted.adoptedSandboxes,
            adoptedVolumes: adopted.adoptedVolumes,
            skippedUnclaimed: adopted.skippedUnclaimed)

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

        try await req.requireAgentAction("agent:manage", on: agent)

        // Never delete a site's designated network controller while the site
        // still has other members: the controller reference deliberately has
        // no FK, so the site would keep pointing at a
        // vanished agent, no member could ever match it, and reconciliation of
        // the site's networks would silently stop. The site's *last* member is
        // the exception — since the first node to join a site is designated
        // automatically (issue #743), refusing there would make a single-node
        // site's only agent undeletable, and once it is gone the site has
        // nothing left to reconcile. Its designation is cleared below instead.
        // Checked before SPIRE deprovisioning so the refusal has no side
        // effects.
        let controlledSites = try await LegacySiteStore.sites(
            networkControllerAgentID: agentId,
            on: req.db)
        for site in controlledSites {
            let remainingMembers = try await LegacyAgentStore.count(
                siteID: site.requireID(), excludingID: agentId, on: req.db)
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
                req,
                registry: registry,
                trustDomain: agent.trustDomain,
                action: "agent",
                on: req.db)
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
            _ = try await LegacySiteStore.setNetworkController(
                siteID: site.requireID(),
                agentID: nil,
                condition: .equals(agentId),
                on: req.db)
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
        if let enrollments {
            try await enrollments.delete(
                trustDomain: agent.trustDomain,
                agentName: agent.name
            )
        }

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

        guard let agents else {
            throw Abort(.internalServerError, reason: "Native agent persistence is unavailable")
        }
        guard let agent = try await agents.agent(id: agentId) else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        try await requireAgentAction("agent:manage", agent: agent, req: req)

        // Force agent offline in in-memory registry
        await req.agentService.forceUnregisterAgent(
            AgentIdentity(trustDomain: agent.trustDomain, name: agent.name)
        )

        // Update database status
        guard try await agents.forceOffline(id: agentId) != nil else {
            throw Abort(.notFound, reason: "Agent not found")
        }

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
        guard let agents else {
            throw Abort(.internalServerError, reason: "Native agent persistence is unavailable")
        }
        guard let agent = try await agents.agent(id: agentId) else {
            throw Abort(.notFound, reason: "Agent not found")
        }

        // Restarting the agent briefly disconnects it and puts every hosted
        // workload through re-adoption, so this falls under the same
        // `agent:manage` check — and the same tier-1 foreign-workload forbid —
        // as force-offline and deregister.
        try await requireAgentAction("agent:manage", agent: agent, req: req)

        let request: AgentUpdateRequest
        if req.headers.contentType != nil {
            request = try req.content.decode(AgentUpdateRequest.self)
        } else {
            request = AgentUpdateRequest()
        }
        let force = request.force == true

        guard agent.isOnline else {
            throw Abort(.conflict, reason: "Agent is offline; it must be connected to receive an update")
        }

        // VMs survive an agent restart regardless of hypervisor: QEMU and
        // Firecracker VMs are both re-adopted via their deterministic control
        // sockets (issue #433), so they need no acknowledgement. Sandboxes do:
        // their runtime driver (issue #421) hasn't landed, so restart-survival
        // is unproven — drop this guard only once it re-adopts them the same
        // way. Make the operator acknowledge that explicitly.
        if !force {
            let sandboxes = try await agents.hostedSandboxCount(id: agentId)
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
            guard
                let explicitVersion = request.targetVersion
                    ?? AgentVersionTarget.version(configuration: req.controlPlaneConfiguration)
            else {
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
            guard
                let target = AgentVersionTarget.version(
                    configuration: req.controlPlaneConfiguration)
            else {
                throw Abort(
                    .badRequest,
                    reason:
                        "No agent target version is configured (dev build). Set AGENT_TARGET_VERSION, or pass artifactUrl and sha256 explicitly."
                )
            }
            guard let os = agent.operatingSystem.flatMap(OperatingSystem.init(rawValue:)) else {
                throw Abort(
                    .conflict,
                    reason:
                        "Agent has not reported its operating system; it must re-register with a build that does before its artifact can be resolved. Pass artifactUrl and sha256 to override."
                )
            }
            guard let architecture = agent.architecture.flatMap(CPUArchitecture.init(rawValue:)) else {
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
        // re-registers at the target. Overwriting an in-flight assignment is
        // deliberate — re-issuing the update is how an operator retries past a
        // recorded failure, and it restarts the health budget with a freshly
        // supplied artifact.
        let artifactJSON: String?
        if let artifactOverride {
            artifactJSON = String(
                data: try JSONEncoder().encode(artifactOverride),
                encoding: .utf8
            )
        } else {
            artifactJSON = nil
        }
        guard
            let assignedAgent = try await agents.assignManualUpdate(
                id: agentId,
                version: targetVersion,
                artifactOverrideJSON: artifactJSON
            )
        else {
            throw Abort(.notFound, reason: "Agent not found")
        }

        req.logger.notice(
            "Agent update assigned",
            metadata: [
                "agentId": .string(agentId.uuidString),
                "agentName": .string(assignedAgent.name),
                "currentVersion": .string(assignedAgent.version),
                "targetVersion": .string(targetVersion),
                // Redacted: explicit overrides may be presigned URLs whose
                // query string is a credential.
                "artifactUrl": .string(DesiredAgentUpdate.redactURL(artifactURL)),
            ])

        // Ring now for low latency; the agent's unconditional refetch is the
        // correctness backstop.
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

    /// Withdraws an agent's update assignment, whoever made it: the version,
    /// the pinned artifact, the health-budget clock, and any recorded
    /// blocker/failure. The next sync stops carrying the desired update.
    ///
    /// This is the counterpart the declarative rewrite needs. An imperative
    /// dispatch had nothing to cancel — it either returned or timed out — but an
    /// assignment is durable, so an update that can never converge (a bad
    /// artifact, a host that died mid-swap) would otherwise sit on the row with
    /// no API able to remove it: it never converges, it is exempt from the
    /// rollout's stale reset, and re-issuing the update is refused while the
    /// agent is offline, which is exactly when it failed. Hence no `isOnline`
    /// guard here — cancelling has to work precisely when assigning does not.
    ///
    /// Idempotent: cancelling an agent with no assignment is a no-op success.
    func cancelAgentUpdate(req: Request) async throws -> AgentResponse {
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }
        guard let agents else {
            throw Abort(.internalServerError, reason: "Native agent persistence is unavailable")
        }
        guard let current = try await agents.agent(id: agentId) else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        try await requireAgentAction("agent:manage", agent: current, req: req)
        guard let result = try await agents.cancelUpdate(id: agentId) else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        if let assigned = result.cancelledVersion {
            req.logger.notice(
                "Agent update assignment cancelled",
                metadata: [
                    "agentId": .string(agentId.uuidString),
                    "agentName": .string(result.agent.name),
                    "targetVersion": .string(assigned),
                ])

            // Push the sync now so a connected agent stops seeing the desired
            // update rather than waiting for the periodic backstop.
            await req.agentService.syncDesiredState(agentId: agentId.uuidString)
        }

        return try AgentResponse(
            from: result.agent,
            targetVersion: AgentVersionTarget.version(configuration: req.controlPlaneConfiguration))
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
        guard let agents else {
            throw Abort(.internalServerError, reason: "Native agent persistence is unavailable")
        }
        guard let current = try await agents.agent(id: agentId) else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        try await requireAgentAction("agent:manage", agent: current, req: req)

        let patch = try req.content.decode(AgentPatchRequest.self)
        let agent: AgentSnapshot
        if let autoUpdate = patch.autoUpdate {
            guard let updated = try await agents.setAutoUpdate(id: agentId, enabled: autoUpdate) else {
                throw Abort(.notFound, reason: "Agent not found")
            }
            agent = updated
            if autoUpdate != current.autoUpdate {
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
        } else {
            agent = current
        }

        return try AgentResponse(
            from: agent,
            targetVersion: AgentVersionTarget.version(configuration: req.controlPlaneConfiguration))
    }

}
