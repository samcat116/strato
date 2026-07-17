import Fluent
import FluentPostgresDriver
import NIOSSL
import Vapor
import OTel
import Valkey

public func configure(_ app: Application) async throws {
    // Capture this process's identity once, before anything else, so the boot log
    // and the /health endpoints can report exactly who is answering. Two control
    // planes on the same port will report different instanceIds — the tell we
    // lacked when a stale duplicate silently intercepted port 8080.
    let identity = InstanceIdentity(environment: app.environment.name)
    app.instanceIdentity = identity
    app.logger.info(
        "Control plane booting",
        metadata: [
            "instanceId": .string(identity.instanceId.uuidString),
            "version": .string(BuildInfo.version),
            "gitSHA": .string(BuildInfo.gitSHA),
            "environment": .string(identity.environment),
        ])

    // Track fire-and-forget background work (async VM operations) so shutdown
    // can drain it before Fluent closes its connection pools. Registered
    // before anything that can spawn work.
    app.setUpBackgroundTaskRegistry()

    // Request logging: one structured line per HTTP request (method/path/status/
    // duration). Registered first so it's the outermost middleware and times the
    // full request. Default on outside production; override with REQUEST_LOGGING.
    let requestLoggingEnabled =
        Environment.get("REQUEST_LOGGING").flatMap(Bool.init)
        ?? (app.environment != .production)
    if requestLoggingEnabled {
        app.middleware.use(RequestLoggingMiddleware())
        app.logger.info("Request logging enabled")
    }

    // Whether browsers reach us over HTTPS. This can't be inferred from the Vapor
    // environment: the published image, single-host compose, and Helm chart all
    // run `--env production` yet default to serving plaintext HTTP (TLS, when
    // present, is terminated at an ingress/proxy we don't see). Defaulting
    // production to TLS would set `Secure` on the session cookie, and browsers on
    // http:// would then drop it — breaking login. So this is opt-in: deployments
    // that terminate TLS set HTTP_TLS_ENABLED=true (the Helm chart derives it from
    // ingress.tls). Governs both HSTS and the Secure cookie flag below.
    let servedOverTLS = Environment.get("HTTP_TLS_ENABLED").flatMap(Bool.init) ?? false
    // Insert at the front so it wraps Vapor's default ErrorMiddleware (which is
    // registered ahead of any `.use`-appended middleware). Otherwise the 4xx/5xx
    // responses ErrorMiddleware synthesizes from thrown errors would flow back out
    // above this middleware and miss the security headers.
    app.middleware.use(SecurityHeadersMiddleware(enableHSTS: servedOverTLS), at: .beginning)

    // Harden the session cookie: always HTTPOnly, and Secure whenever we're
    // behind TLS so the cookie can't leak over a downgraded/plaintext request.
    // SameSite=lax keeps the cookie on top-level navigations (needed for the
    // OAuth/OIDC redirect back into the app) while blocking cross-site sends.
    app.sessions.configuration = .init(cookieName: "vapor-session") { sessionID in
        HTTPCookies.Value(
            string: sessionID.string,
            path: "/",
            isSecure: servedOverTLS,
            isHTTPOnly: true,
            sameSite: .lax
        )
    }

    // Valkey backs the coordination layer (agent presence, singleton sweep
    // locks, scheduler placement reservations — issue #258) and session
    // storage. Coordination *requires* it: without a shared store, replicas
    // disagree about agent liveness and race on placement, so startup fails
    // hard when Valkey is missing or unreachable rather than silently
    // degrading. Tests run without external services and use an in-process
    // coordination store (and Fluent sessions) instead.
    if app.environment == .testing {
        app.coordination = CoordinationService(store: InMemoryCoordinationStore(), logger: app.logger)
        app.sessions.use(.fluent)
    } else {
        guard let valkeyConfig = ValkeyConfiguration.fromEnvironment() else {
            let error = CoordinationConfigurationError.valkeyNotConfigured
            app.logger.critical("\(error.description)")
            throw error
        }
        app.configureValkey(valkeyConfig)
        app.sessions.use(.valkey)
        app.coordination = CoordinationService(store: ValkeyCoordinationStore(app: app), logger: app.logger)
        // Fail fast at boot (after the Valkey run loop starts) if Valkey is unreachable.
        app.lifecycle.use(
            CoordinationLifecycleHandler(hostname: valkeyConfig.hostname, port: valkeyConfig.port))
        app.logger.info("Using Valkey for coordination and session storage")
    }
    app.middleware.use(app.sessions.middleware)

    // At-rest encryption for recoverable secrets (OIDC client secrets, SSF
    // stream auth tokens). A malformed key fails startup — a typo must not
    // silently downgrade to plaintext storage — while an absent key runs
    // pass-through with a warning so existing deployments keep working until
    // the operator sets one.
    let secretsEncryption = try SecretsEncryptionService.fromEnvironment()
    app.secretsEncryption = secretsEncryption
    if !secretsEncryption.isEnabled {
        app.logger.warning(
            "STRATO_SECRET_ENCRYPTION_KEY is not set — OIDC client secrets and SSF auth tokens will be stored unencrypted. Generate a key with `openssl rand -hex 32` and set it to enable encryption at rest."
        )
    }

    // Registry client for sandbox tag→digest resolution and pull-token
    // minting (issue #414). Tests get the no-network client so sync assembly
    // never does registry I/O in the suite; tests that exercise the flow
    // install a scripted client of their own.
    app.registryClient =
        app.environment == .testing
        ? NoopRegistryClient()
        : DistributionRegistryClient(app: app)

    // Configure user authentication with sessions
    app.middleware.use(User.sessionAuthenticator())

    // Configure API key authentication (for Bearer tokens)
    app.middleware.use(BearerAuthorizationHeaderAuthenticator())

    // Rate limiting: throttle per-IP (unauthenticated) and per-user
    // (authenticated). Registered after the authenticators so it can bucket by
    // the resolved user, and before authorization/controllers so throttled
    // requests are rejected before doing real work. Uses Valkey when configured
    // (shared across replicas), else a process-local counter. See issue #60.
    let rateLimitConfig = RateLimitConfig.fromEnvironment(for: app.environment)
    if rateLimitConfig.enabled {
        app.middleware.use(
            RateLimitMiddleware(
                config: rateLimitConfig,
                fallbackStore: InMemoryRateLimitStore()
            ))
        app.logger.info(
            "Rate limiting enabled",
            metadata: [
                "authLimit": .stringConvertible(rateLimitConfig.authLimit),
                "apiLimit": .stringConvertible(rateLimitConfig.apiLimit),
            ])
    }

    // Audit logging (issue #39): durable audit events for API mutations, auth
    // flows, and system-admin activity, fanned out to configurable backends
    // (AUDIT_BACKENDS; database by default). Registered after the
    // authenticators (so events carry the resolved actor) and rate limiter
    // (so throttled spam is not audited), and before the scope and
    // authorization middleware so denied requests — API-key scope 403s
    // included — are audited with their real status. No-ops when
    // AUDIT_ENABLED=false.
    app.middleware.use(AuditMiddleware())

    // Enforce the scopes attached to an API key. Must run after the bearer
    // authenticator above (which populates request.apiKey) so it can see the
    // key; a no-op for session-authenticated requests (issue #173).
    app.middleware.use(APIKeyScopeMiddleware())

    // Enforce per-user security state set by SSF signal handlers (issue #38):
    // disabled accounts and revoked sessions (session-epoch mismatch). After
    // both authenticators and the audit middleware (so denials are audited),
    // before authorization.
    app.middleware.use(UserSecurityMiddleware())

    // Configure WebAuthn
    let relyingPartyID = Environment.get("WEBAUTHN_RELYING_PARTY_ID") ?? "localhost"
    let relyingPartyName = Environment.get("WEBAUTHN_RELYING_PARTY_NAME") ?? "Strato"
    let relyingPartyOrigin = Environment.get("WEBAUTHN_RELYING_PARTY_ORIGIN") ?? "http://localhost:8080"

    app.configureWebAuthn(
        relyingPartyID: relyingPartyID,
        relyingPartyName: relyingPartyName,
        relyingPartyOrigin: relyingPartyOrigin
    )

    if app.environment != .testing {
        // Fail fast: the SpiceDB service is constructed lazily on every authorized
        // request, so validate its required configuration at boot rather than
        // letting the first request that touches it error out. Skipped under
        // .testing, which resolves `app.spicedb` to an in-memory mock and needs no
        // real endpoint or preshared key.
        try app.validateSpiceDBConfiguration()
    }

    // Register the authorization middleware in every environment — including
    // .testing. It used to be skipped under .testing, which meant every controller
    // test ran with authorization off and no test could catch an authz regression
    // (issue #196). In testing, `app.spicedb` resolves to a mock whose verdict is
    // controlled by `app.spicedbMockAllows`, so tests can exercise both the
    // allow and deny paths through the real middleware + handler stack.
    app.middleware.use(SpiceDBAuthMiddleware())

    // Configure database based on environment
    if app.environment == .testing {
        // Testing environment already configured with in-memory SQLite in test setup
        // Skip database configuration here
    } else {
        // TLS mode is configurable via DATABASE_TLS (disable|prefer|require) and
        // defaults to `require` outside development, so credentials and data are
        // encrypted whenever Postgres is remote. See issue #56.
        let databaseTLS = try makeDatabaseTLS(for: app.environment, logger: app.logger)
        app.databases.use(
            DatabaseConfigurationFactory.postgres(
                configuration: .init(
                    hostname: Environment.get("DATABASE_HOST") ?? "localhost",
                    port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
                        ?? SQLPostgresConfiguration.ianaPortNumber,
                    username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
                    password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
                    database: Environment.get("DATABASE_NAME") ?? "vapor_database",
                    tls: databaseTLS)
            ), as: .psql)
    }

    app.migrations.add(CreateUser())
    app.migrations.add(CreateVM())
    app.migrations.add(CreateOrganization())
    app.migrations.add(AddCurrentOrganizationToUser())
    app.migrations.add(CreateAPIKey())
    app.migrations.add(SessionRecord.migration)
    app.migrations.add(EnhanceVM())
    app.migrations.add(FixVMColumnNames())
    app.migrations.add(AddSystemAdminToUser())

    // SSF security state on users (issue #38). Registered early — before any
    // data migration that loads the User model — because the model selects
    // these columns (same ordering constraint as AddStatusChangedAtToVM).
    app.migrations.add(AddSecurityStateToUser())

    // Hierarchical IAM migrations
    app.migrations.add(CreateOrganizationalUnit())
    app.migrations.add(CreateProject())
    app.migrations.add(CreateResourceQuota())
    app.migrations.add(AddProjectToVM())
    app.migrations.add(MigrateExistingDataToProjects())
    app.migrations.add(MakeProjectRequiredOnVM())

    // Groups migrations
    app.migrations.add(CreateGroup())
    app.migrations.add(CreateUserGroup())

    // OIDC migrations
    app.migrations.add(CreateOIDCProvider())
    app.migrations.add(AddOIDCFieldsToUser())
    // Agent migrations
    app.migrations.add(CreateAgent())
    app.migrations.add(CreateAgentRegistrationToken())
    app.migrations.add(AddSPIREProvisionedToAgentRegistrationToken())

    // SCIM migrations
    app.migrations.add(CreateSCIMToken())
    app.migrations.add(CreateSCIMExternalID())
    app.migrations.add(AddSCIMFieldsToUser())
    app.migrations.add(AddSCIMFieldsToGroup())
    // Admin-created users: explicit account provenance + passkey-claim invites.
    // Must run before any data migration that loads the live `User` model
    // (e.g. MigrateVMDisksToVolumes) — the model now selects the required
    // `source` column, so it has to exist by then. Ordered after the OIDC/SCIM
    // user-field migrations because the backfill reads those columns.
    app.migrations.add(AddSourceToUser())
    app.migrations.add(CreateAccountClaimToken())
    app.migrations.add(AlterSCIMTokenForeignKey())
    app.migrations.add(AddSCIMExternalIDIndex())

    // Image management migrations
    app.migrations.add(CreateImage())
    app.migrations.add(AddImageToVM())

    // Image metadata: architecture + typed artifact sets (#214)
    app.migrations.add(AddArchitectureToImage())
    app.migrations.add(CreateImageArtifact())
    app.migrations.add(BackfillImageArtifacts())
    app.migrations.add(AddFetchStateToImageArtifact())

    // Caller-supplied checksum for URL imports
    app.migrations.add(AddExpectedChecksumToImage())

    // Hypervisor type migration
    app.migrations.add(AddHypervisorTypeToVM())
    app.migrations.add(AddHypervisorTypeToAgent())

    // VM state reconciliation: must run before any data migration that loads the VM
    // model (e.g. MigrateVMDisksToVolumes), since the model now selects this column.
    app.migrations.add(AddStatusChangedAtToVM())

    // Desired/observed state split (reconciliation phase 2, issue #260). Same
    // ordering constraint as above: the VM model selects these columns.
    app.migrations.add(AddDesiredStateToVM())

    // SSH public key column. Same ordering constraint as above — the VM model
    // selects this column, so it must exist before any data migration that
    // loads VM models (e.g. MigrateVMDisksToVolumes) runs on a fresh database.
    app.migrations.add(AddSSHPublicKeyToVM())

    // App settings migration (for signing keys, etc.)
    app.migrations.add(CreateAppSetting())

    // Volume management migrations
    app.migrations.add(CreateVolume())
    app.migrations.add(MigrateVMDisksToVolumes())

    // Multi-hypervisor capability reporting (issue #208)
    app.migrations.add(ReplaceAgentHypervisorTypeWithHypervisors())

    // Index the hottest VM columns scanned by background jobs (issue #182)
    app.migrations.add(AddVMHotColumnIndexes())

    // Multi-NIC support: move the legacy single-NIC columns on vms into
    // vm_network_interfaces records, then drop them (issue #215)
    app.migrations.add(CreateVMNetworkInterface())
    app.migrations.add(MigrateVMNetworkConfigToInterfaces())
    app.migrations.add(RemoveLegacyVMNetworkFields())

    // Async VM operations (issue #259)
    app.migrations.add(CreateVMOperation())

    // Logical networks + control-plane IPAM (issue #212)
    app.migrations.add(CreateLogicalNetwork())
    app.migrations.add(AddGatewayToVMNetworkInterface())

    // Project-scoped networks exposed via the API
    app.migrations.add(AddProjectToLogicalNetwork())

    // OVN DHCP/DNS configuration on logical networks
    app.migrations.add(AddDHCPConfigToLogicalNetwork())

    // L3: per-project router + SNAT uplink desired-state on logical networks (issue #342)
    app.migrations.add(AddExternalAccessToLogicalNetwork())

    // Project-level roles: user and group grants on individual projects.
    app.migrations.add(CreateProjectMember())
    app.migrations.add(CreateProjectGroupGrant())

    // Sites (availability zones): group agents sharing one OVN deployment so a
    // logical network can span nodes (issue #343).
    app.migrations.add(CreateSite())
    app.migrations.add(AddWireProtocolVersionToAgent())

    // Centralized audit logging (issue #39)
    app.migrations.add(CreateAuditEvent())

    // Drop the legacy vm_templates table (VM template feature removed).
    app.migrations.add(DropVMTemplate())

    // Shared Signals Framework receiver streams (issue #38)
    app.migrations.add(CreateSSFStream())

    // Dual-stack networking: NIC addresses normalized into their own table,
    // one row per family (issue: IPv6 support).
    app.migrations.add(CreateVMInterfaceAddresses())
    app.migrations.add(AddIPv6ToLogicalNetwork())

    // Organization-scoped infrastructure: agents/sites/registration tokens
    // carry a mandatory org-or-OU owner (backfilled to the oldest org).
    app.migrations.add(AddOrganizationScopeToInfra())
    app.migrations.add(BackfillInfraOrganizationScope())

    // One release after CreateVMInterfaceAddresses: the rollback window for
    // the legacy single-address NIC columns is over, drop them.
    app.migrations.add(DropLegacyVMInterfaceAddressColumns())

    // Storage phase 1 (issue #349): pools + per-volume replicas; existing
    // volumes are adopted into the seeded default local pool.
    app.migrations.add(CreateStoragePool())
    app.migrations.add(CreateVolumeReplica())
    app.migrations.add(AddStoragePoolToVolume())
    app.migrations.add(BackfillVolumePools())

    // OIDC authz & identity mapping (issue #363): group/role claim mapping and
    // configurable default role on the provider.
    app.migrations.add(AddClaimMappingToOIDCProvider())

    // Store the provider's expected issuer (from discovery) so the login flow can
    // validate the ID token's `iss` claim.
    app.migrations.add(AddIssuerToOIDCProvider())

    // OIDC protocol completeness (issue #365): the provider's end-session
    // endpoint enables RP-initiated logout at the IdP.
    app.migrations.add(AddEndSessionEndpointToOIDCProvider())

    // Per-provider nonce toggle: some IdPs (e.g. Discord) accept but never
    // echo the OIDC nonce, so allow disabling it to avoid failing every login.
    app.migrations.add(AddUseNonceToOIDCProvider())

    // Generalize the async-operation machinery beyond VMs (issue #412):
    // vm_operations becomes resource_operations with a resource_kind
    // discriminator, so new resource types reuse the 202/poll/sweep pattern.
    app.migrations.add(GeneralizeVMOperations())

    // Sandboxes (issue #413): OCI-image Firecracker microVMs as a first-class
    // workload type, parallel to VMs.
    app.migrations.add(CreateSandbox())

    // Registry pull secrets (issue #414): per-project credentials for private
    // OCI registries, encrypted at rest.
    app.migrations.add(CreateRegistryPullSecret())

    // Agent OS reporting for update artifact resolution (issue #432).
    app.migrations.add(AddOperatingSystemToAgent())

    // Sandbox scheduler gating + quota accounting (issue #415): agents record
    // whether they advertised the sandbox runtime, and quotas grow a sandbox
    // count limit beside the VM one.
    app.migrations.add(AddSandboxCapableToAgent())
    app.migrations.add(AddSandboxCountToResourceQuota())

    // Sandbox NIC + IPAM integration (issue #416): a per-sandbox NIC on a
    // logical network with per-family address rows, allocated by the same IPAM
    // as VMs.
    app.migrations.add(CreateSandboxNetworkInterface())
    app.migrations.add(CreateSandboxInterfaceAddresses())

    // Declarative agent auto-update (issue #434): per-agent opt-in and the
    // fleet rollout's bookkeeping columns.
    app.migrations.add(AddAgentAutoUpdate())

    // Descriptive host hardware/platform/OS details for operator display.
    app.migrations.add(AddHostInfoToAgent())

    try await app.autoMigrate()

    // Converge any plaintext stored secrets (OIDC client secrets, SSF auth
    // tokens) to encrypted form. Runs every startup (not a one-shot migration)
    // so a key added after upgrade still picks up rows written before it
    // existed. No-op without a key.
    try await secretsEncryption.encryptStoredSecrets(on: app.db, logger: app.logger)

    // Load the SpiceDB schema if SpiceDB doesn't have one yet. Must happen
    // before anything writes relationships — the dev auth bypass below is the
    // first writer on a fresh stack and crashes with a 400 without a schema.
    if app.environment != .testing {
        try await ensureSpiceDBSchema(app)
        // Backfill SpiceDB tuples so existing data authorizes correctly after the
        // schema/tuple reset and now that SpiceDB is the sole authorization source.
        // Each is a single chunked idempotent (TOUCH) batch. OU parents first so the
        // project#parent → organizational_unit → organization chain resolves.
        //  - organizational_unit#parent tuples (parent OU or organization).
        //  - project#parent tuples against each project's immediate parent.
        //  - organization#<role>→user tuples for every relational membership, so
        //    existing members don't 403 once relational role checks are retired.
        try await backfillOrganizationalUnitParentRelationships(app)
        try await backfillProjectOrganizationRelationships(app)
        try await backfillOrganizationMemberRelationships(app)
        //  - agent#parent / site#parent tuples for org-scoped infrastructure.
        try await backfillInfraParentRelationships(app)
    }

    // Initialize the image download signing key (generates if not exists)
    _ = try await URLSigningService.getSigningKeyAsync(from: app)

    // Dev auth bypass - create dev user for local development
    if app.environment == .development, Environment.get("DEV_AUTH_BYPASS") == "true" {
        app.logger.critical(
            """
            ============================================================
            ⚠️  DEV_AUTH_BYPASS ENABLED — AUTHENTICATION IS DISABLED  ⚠️
            Every request is served as a system-admin 'dev' user with no
            credentials required. This is for LOCAL DEVELOPMENT ONLY.
            Never enable DEV_AUTH_BYPASS on a host reachable by anyone else.
            ============================================================
            """)
        let devUser: User
        if let existingUser = try await User.query(on: app.db)
            .filter(\.$username == "dev")
            .first()
        {
            devUser = existingUser
        } else {
            devUser = User(
                username: "dev",
                email: "dev@localhost",
                displayName: "Dev User",
                isSystemAdmin: true
            )
            try await devUser.save(on: app.db)
            app.logger.info("Created dev user for auth bypass")
        }
        // Ensure dev user has a default organization
        let defaultOrg: Organization
        if let existingOrg = try await Organization.query(on: app.db)
            .filter(\.$name == "Default Organization")
            .first()
        {
            defaultOrg = existingOrg
        } else {
            defaultOrg = Organization(
                name: "Default Organization",
                description: "Default organization for development"
            )
            try await defaultOrg.save(on: app.db)
            app.logger.info("Created default organization for dev user")
        }

        // Ensure default project exists for the organization
        let defaultProject: Project
        if let existingProject = try await Project.query(on: app.db)
            .filter(\.$organization.$id == defaultOrg.id!)
            .filter(\.$name == "Default Project")
            .first()
        {
            defaultProject = existingProject
        } else {
            defaultProject = Project(
                name: "Default Project",
                description: "Default project for Default Organization",
                organizationID: defaultOrg.id,
                path: "/\(defaultOrg.id!.uuidString)"
            )
            try await defaultProject.save(on: app.db)

            // Update project path with its own ID
            defaultProject.path = "/\(defaultOrg.id!.uuidString)/\(defaultProject.id!.uuidString)"
            try await defaultProject.save(on: app.db)
            app.logger.info("Created default project for dev organization")
        }

        // Always ensure SpiceDB relationships exist (idempotent)
        // This handles cases where DB state exists but SpiceDB was reset
        // Catch 409 conflicts since they just mean the relationship already exists
        do {
            try await app.spicedb.writeRelationship(
                entity: "organization",
                entityId: defaultOrg.id!.uuidString,
                relation: "admin",
                subject: "user",
                subjectId: devUser.id!.uuidString
            )
        } catch SpiceDBError.relationshipWriteFailed(let status) where status == .conflict {
            // Relationship already exists, which is fine
        }

        do {
            try await app.spicedb.writeRelationship(
                entity: "project",
                entityId: defaultProject.id!.uuidString,
                relation: "parent",
                subject: "organization",
                subjectId: defaultOrg.id!.uuidString
            )
        } catch SpiceDBError.relationshipWriteFailed(let status) where status == .conflict {
            // Relationship already exists, which is fine
        }

        // Link dev user to organization if not already linked
        let existingMembership = try await UserOrganization.query(on: app.db)
            .filter(\.$user.$id == devUser.id!)
            .filter(\.$organization.$id == defaultOrg.id!)
            .first()

        if existingMembership == nil {
            let membership = UserOrganization(
                userID: devUser.id!,
                organizationID: defaultOrg.id!,
                role: "admin"
            )
            try await membership.save(on: app.db)
        }

        // Set current organization if not set
        if devUser.currentOrganizationId == nil {
            devUser.currentOrganizationId = defaultOrg.id
            try await devUser.save(on: app.db)
        }

        app.storage[DevUserKey.self] = devUser
    }

    // Configure scheduler service
    // Default strategy can be configured via environment variable
    let schedulingStrategy =
        Environment.get("SCHEDULING_STRATEGY")
        .flatMap { SchedulingStrategy(rawValue: $0) } ?? .leastLoaded
    app.useScheduler(SchedulerService(logger: app.logger, defaultStrategy: schedulingStrategy))
    app.logger.info("Scheduler service initialized with strategy: \(schedulingStrategy.rawValue)")

    // Configure SPIFFE/SPIRE authentication (if enabled via environment)
    try await app.configureSPIRE()

    // Configure SPIRE join-token provisioning for the agent registration flow
    // (requires SPIRE_ENABLED plus SPIRE_SERVER_API_ADDRESS)
    try app.configureSPIRERegistration()

    // Configure OpenTelemetry observability (metrics, logs, traces)
    if app.environment != .testing {
        let metricsEnabled = Environment.get("OTEL_METRICS_ENABLED").flatMap(Bool.init) ?? true
        let logsEnabled = Environment.get("OTEL_LOGS_ENABLED").flatMap(Bool.init) ?? true
        let tracesEnabled = Environment.get("OTEL_TRACES_ENABLED").flatMap(Bool.init) ?? true

        // Only bootstrap OpenTelemetry if at least one feature is enabled
        if metricsEnabled || logsEnabled || tracesEnabled {
            var otelConfig = OTel.Configuration.default
            otelConfig.serviceName = Environment.get("OTEL_SERVICE_NAME") ?? "strato-control-plane"

            // Enable all three pillars of observability
            otelConfig.metrics.enabled = metricsEnabled
            otelConfig.logs.enabled = logsEnabled
            otelConfig.traces.enabled = tracesEnabled

            // Configure OTLP exporter protocol (defaults to gRPC on port 4317)
            // Can be overridden with OTEL_EXPORTER_OTLP_ENDPOINT environment variable
            #if os(macOS)
            if #available(macOS 15, *) {
                otelConfig.metrics.otlpExporter.protocol = .grpc
                otelConfig.logs.otlpExporter.protocol = .grpc
                otelConfig.traces.otlpExporter.protocol = .grpc
            }
            #else
            otelConfig.metrics.otlpExporter.protocol = .grpc
            otelConfig.logs.otlpExporter.protocol = .grpc
            otelConfig.traces.otlpExporter.protocol = .grpc
            #endif

            app.logger.info(
                "Bootstrapping OpenTelemetry",
                metadata: [
                    "service": .string(otelConfig.serviceName),
                    "metrics": .stringConvertible(otelConfig.metrics.enabled),
                    "logs": .stringConvertible(otelConfig.logs.enabled),
                    "traces": .stringConvertible(otelConfig.traces.enabled),
                ])

            let observability = try OTel.bootstrap(configuration: otelConfig)
            app.lifecycle.use(OTelLifecycleHandler(observability: observability))
            app.logger.info("OpenTelemetry observability service registered")
        } else {
            app.logger.info("OpenTelemetry disabled, skipping bootstrap")
        }
    }

    // The agent service's heartbeat monitor must not outlive the application:
    // the handler cancels it at shutdown (if the service was ever created).
    app.lifecycle.use(AgentServiceLifecycleHandler())

    // Audit retention (issue #39): when AUDIT_RETENTION_DAYS is set, an
    // hourly cluster-singleton sweep prunes audit_events rows older than the
    // cutoff. The handler arms the sweep at boot and cancels it at shutdown.
    app.lifecycle.use(AuditRetentionLifecycleHandler())

    // SSF poll delivery (issue #38): periodically drain poll-delivery streams
    // from their transmitters. The handler arms the sweep at boot and cancels
    // it at shutdown.
    app.lifecycle.use(SSFPollLifecycleHandler())

    try routes(app)

    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
}
