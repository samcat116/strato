import Fluent
import FluentPostgresDriver
import NIOSSL
import Vapor
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

    // OpenTelemetry (metrics, logs, traces) goes in first, ahead of every client
    // this function configures. Instrumented clients capture
    // `InstrumentationSystem.tracer` when their *configuration* is built, not
    // per request — bootstrapping later left the shared HTTP client and the
    // Valkey client holding a NoOpTracer for the process lifetime, so neither
    // emitted spans. See `Application.bootstrapObservability` for the details.
    try app.bootstrapObservability()

    // Track fire-and-forget background work (async VM operations) so shutdown
    // can drain it before Fluent closes its connection pools. Registered
    // before anything that can spawn work.
    app.setUpBackgroundTaskRegistry()

    // How far to trust `X-Forwarded-For`, shared by rate limiting, audit
    // `sourceIP`, and API-key `lastUsedIP` so one request resolves to one
    // address everywhere. Set before any middleware that reads it.
    app.proxyTrust = .fromEnvironment()

    // The shared HTTP client is for OPERATOR-CONFIGURED destinations only —
    // Loki, the audit/SSF forwarders, the SPIRE issuance-metrics endpoint, and
    // `AgentUpdateArtifacts`. Anything whose destination a tenant can influence
    // (image `sourceURL` fetches, OCI registry manifests and token realms,
    // webhook deliveries, OIDC discovery/token/userinfo/JWKS) goes through
    // `app.guardedHTTPClient`, which validates the host, pins the connection to
    // the address it approved, and refuses redirects. Reaching for `app.client`
    // or `app.http.client.shared` on a tenant-influenced fetch is the bug that
    // class of endpoint keeps reintroducing.
    //
    // Redirect-following is off here as a backstop: a 3xx from a validated host
    // would otherwise let the client silently follow it to an internal address
    // (cloud metadata, loopback, private services), defeating the check.
    // Callers that legitimately need redirects follow them explicitly:
    // `ImageFetchService` makes one guarded request per hop, and
    // `AgentUpdateArtifacts` follows the release host's CDN redirect by hand
    // (its base URL is operator-configured, never tenant-supplied, and carries
    // no credentials — that exemption is documented on `GuardedHTTPClient`).
    app.http.client.configuration.redirectConfiguration = .disallow

    // The ceiling on any request body Vapor collects into memory before a
    // handler sees it (STR-195). Vapor's default is 16 MB, which was the only
    // size bound in the entire persist path — no column is length-limited, so
    // 16 MB was the implicit contract of every endpoint, including `POST
    // /api/vms`.
    //
    // 1 MiB is chosen against the largest legitimate collected body: a VM
    // create carrying `CloudInitUserDataFormat.maxBytes` (64 KiB) of user data
    // plus a 4 KiB `cmdline` and its metadata, with an order of magnitude of
    // headroom for the JSON-heavy bodies (Cedar policy text, SCIM payloads)
    // that have no single large field but many.
    //
    // The three routes that legitimately carry gigabytes — image upload, image
    // artifact upload, and sandbox snapshot artifact transfer — are registered
    // with `body: .stream` and are unaffected: a streaming route never
    // collects, and each already enforces its own byte ceiling.
    app.routes.defaultMaxBodySize = "1mb"

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

    // Observability middleware, registered high in the stack so they time the
    // full request and so downstream child spans (authz, scheduler, etc.) nest
    // under the per-request server span:
    //  - Vapor's TracingMiddleware extracts inbound W3C trace context, opens one
    //    server span per request with HTTP semantic-convention attributes, and
    //    publishes it on request.serviceContext for the rest of the chain.
    //  - MetricsMiddleware emits RED metrics (count + duration) for every route.
    // Both go through the swift-otel-backed facades, which are no-ops when the
    // respective pillar is disabled, so they are always safe to register.
    app.middleware.use(TracingMiddleware())
    app.middleware.use(MetricsMiddleware())

    // Whether browsers reach us over HTTPS. This can't be inferred from the Vapor
    // environment: the published image, single-host compose, and Helm chart all
    // run `--env production` yet default to serving plaintext HTTP (TLS, when
    // present, is terminated at an ingress/proxy we don't see). Defaulting
    // production to TLS would set `Secure` on the session cookie, and browsers on
    // http:// would then drop it — breaking login. So this is opt-in: deployments
    // that terminate TLS set HTTP_TLS_ENABLED=true (the Helm chart derives it from
    // the resolved browser-facing origin). Governs both HSTS and the Secure cookie
    // flag below.
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

    // Valkey backs two stores with opposite failure contracts, so they are
    // configured separately (issue #855):
    //
    //  - **Coordination** (agent presence, singleton sweep locks, scheduler
    //    placement reservations — issue #258) is fail-open by design. Losing a
    //    reservation may make one create reach a now-full node and be refused;
    //    the agent's admission gate, not Valkey, prevents host overcommit.
    //  - **Session storage** cannot fail open at all. Losing it logs every
    //    signed-in user out at once, and passkeys are the only interactive auth,
    //    so everyone re-authenticates with a security key.
    //
    // Coordination keeps the historical `VALKEY_*` variables and is required —
    // without a shared store, replicas disagree about agent liveness and race on
    // placement, so startup fails hard rather than silently degrading. Sessions
    // follow that same endpoint unless `SESSION_VALKEY_HOST` names another, so a
    // deployment that only ever set `VALKEY_HOST` upgrades untouched, down to
    // opening the same single connection pool.
    //
    // Tests run without external services and use an in-process coordination
    // store (and Fluent sessions) instead.
    if app.environment == .testing {
        app.coordination = CoordinationService(store: InMemoryCoordinationStore(), logger: app.logger)
        app.sessions.use(.fluent)
    } else {
        guard let valkeyConfig = ValkeyStoreConfiguration.fromEnvironment() else {
            let error = ValkeyConfigurationError.notConfigured
            app.logger.critical("\(error.description)")
            throw error
        }
        app.configureValkey(valkeyConfig)

        // Held on the application as well as handed to the driver, so
        // `/health/ready` can probe session storage without reaching through
        // Vapor's session provider.
        let sessionStore = ValkeySessionStore(client: app.sessionValkey)
        app.sessionStore = sessionStore
        app.sessions.use(.valkey(store: sessionStore))

        app.coordination = CoordinationService(store: ValkeyCoordinationStore(app: app), logger: app.logger)
        // Fail fast at boot (after the run loops start) if either endpoint is
        // unreachable. Both are fatal: coordination fails open against a runtime
        // blip, but an endpoint that is wrong at boot is a misconfiguration.
        app.lifecycle.use(ValkeyReachabilityLifecycleHandler(configuration: valkeyConfig))
        app.logger.info(
            valkeyConfig.sharesOneInstance
                ? "Using one Valkey endpoint for coordination and session storage"
                : "Using separate Valkey endpoints for coordination and session storage")
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

    // Release-artifact resolution for agent updates (issue #432). Tests get a
    // resolver that refuses rather than one that dials the release host, so no
    // suite can depend on github.com being reachable — and a test whose stub
    // never took says so instead of failing as a 404, which is what made the
    // AgentAutoUpdateTests.staleTargetIsReset flake so hard to read. Tests that
    // exercise the flow install a stub of their own.
    app.agentArtifactResolver =
        app.environment == .testing
        ? .refusing("The test environment resolves no release artifacts; install a stub resolver in the test.")
        : .releaseHost(app: app)

    // Where image bytes live. Filesystem by default so existing deployments
    // upgrade untouched; IMAGE_STORAGE_BACKEND=s3 moves them to object storage
    // (required on Kubernetes, where the control plane has no persistent
    // volume and replicas don't share one — see docs/architecture/storage.md).
    // Tests install a store directly and must not read the environment here.
    if app.environment != .testing {
        try ImageObjectStoreFactory.configure(app)
    }

    // Authenticate bearer credentials before installing the session
    // authenticator. Vapor's SessionAuthenticator persists any User that a
    // downstream middleware authenticated into the session on the response
    // path. With the opposite order, every API-key request silently created a
    // browser session and therefore depended on the session Valkey even when
    // it arrived without a cookie (STR-206). A bearer credential is already
    // self-contained; it must never be promoted into a browser session.
    app.middleware.use(BearerAuthorizationHeaderAuthenticator())

    // Configure browser-session authentication after bearer auth. Cookie-only
    // requests still restore and refresh their session exactly as before.
    app.middleware.use(User.sessionAuthenticator())

    // Put the task-local `ServiceContext` back after the last future-based
    // middleware in the stack. Vapor's `SessionsMiddleware` and
    // `User.sessionAuthenticator()` chain downstream from inside an
    // `EventLoopFuture` callback, which severs the Swift task the middleware
    // above was running on and with it the context `TracingMiddleware` bound —
    // so without this every span opened below (`iam.authorize`, the rate
    // limiter's Valkey command, every controller's `fluent.query`) would start
    // its own trace. Anything future-based added after this point needs another
    // one of these behind it; see the middleware's own doc comment.
    app.middleware.use(ServiceContextRestoringMiddleware())

    // Rate limiting: throttle per-IP (unauthenticated) and per-user
    // (authenticated). Registered after the authenticators so it can bucket by
    // the resolved user, and before authorization/controllers so throttled
    // requests are rejected before doing real work. Uses Valkey when configured
    // (shared across replicas), else a process-local counter. See issue #60.
    let rateLimitConfig = RateLimitConfig.fromEnvironment(for: app.environment)
    let rateLimitFallbackStore = InMemoryRateLimitStore()
    let valkeyRateLimitStore =
        app.valkeyEnabled ? ValkeyRateLimitStore(client: app.coordinationValkey) : nil
    // Agent minting authenticates inside its controller, after this global
    // middleware runs. Give it the same policy and stores but a dedicated,
    // verified-agent key space so every Envoy sidecar request does not share
    // the loopback-IP API bucket.
    app.agentGuestIdentityRateLimiter = AgentGuestIdentityRateLimiter(
        config: rateLimitConfig,
        fallbackStore: rateLimitFallbackStore,
        valkeyStore: valkeyRateLimitStore)
    if rateLimitConfig.enabled {
        app.middleware.use(
            RateLimitMiddleware(
                config: rateLimitConfig,
                fallbackStore: rateLimitFallbackStore,
                // Coordination, not sessions: these are cross-replica counters
                // whose backend errors fail open without rejecting the request,
                // which is exactly the coordination contract.
                valkeyStore: valkeyRateLimitStore
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
    // (so throttled spam is not audited), and before the credential-restriction
    // and authorization middleware so denied requests — restricted-credential
    // 403s included — are audited with their real status. No-ops when
    // AUDIT_ENABLED=false.
    app.middleware.use(AuditMiddleware())

    // Backstop for the routes a credential restriction cannot reach through the
    // evaluator: the identity-plane and public mutations that authorize by row
    // scoping rather than by decision (STR-115). Everything else is enforced
    // inside Cedar. Must run after the bearer authenticator above, which
    // populates request.apiKey / request.cliSession.
    app.middleware.use(CredentialRestrictionMiddleware())

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

    // Whether visitors may create their own accounts. Read once at boot: the
    // login page asks for the effective answer over /api/public/registration.
    app.registrationPolicy = .fromEnvironment()
    if !app.registrationPolicy.selfRegistrationEnabled {
        app.logger.info(
            "Self-registration is disabled; only the first (bootstrap) account may be self-created",
            metadata: ["setting": .string(RegistrationPolicy.environmentKey)]
        )
    }

    // Register the authorization middleware in every environment — including
    // .testing. It used to be skipped under .testing, which meant every controller
    // test ran with authorization off and no test could catch an authz regression
    // (issue #196). Since cutover (#482) authorization is evaluated by the
    // in-process Cedar policy set against real `role_bindings` rows, so tests
    // exercise the exact production decision path — there is no permissive mock
    // in front of it.
    app.middleware.use(AuthorizationMiddleware())

    // Configure database based on environment
    var databaseStatementTimeouts: SchemaMigrator.StatementTimeouts?
    if app.environment == .testing {
        // Testing environment already configured with a per-test Postgres
        // database clone in test setup — skip database configuration here
    } else {
        // TLS mode is configurable via DATABASE_TLS (disable|prefer|require) and
        // defaults to `require` outside development, so credentials and data are
        // encrypted whenever Postgres is remote. See issue #56.
        let databaseTLS = try makeDatabaseTLS(for: app.environment, logger: app.logger)
        let statementTimeout = try DatabaseStatementTimeout.fromEnvironment()
        let migrationStatementTimeout = try DatabaseStatementTimeout.migrationFromEnvironment(
            defaultingTo: statementTimeout
        )
        databaseStatementTimeouts = .init(
            normal: statementTimeout,
            migration: migrationStatementTimeout
        )
        let databaseConfiguration = SQLPostgresConfiguration(
            hostname: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
                ?? SQLPostgresConfiguration.ianaPortNumber,
            username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
            password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
            database: Environment.get("DATABASE_NAME") ?? "vapor_database",
            tls: databaseTLS
        )
        app.logger.info(
            "Database statement timeouts configured",
            metadata: [
                "servingMilliseconds": .stringConvertible(statementTimeout.milliseconds),
                "migrationMilliseconds": .stringConvertible(migrationStatementTimeout.milliseconds),
            ]
        )
        app.databases.use(
            statementTimeout.applying(
                to: DatabaseConfigurationFactory.postgres(
                    configuration: databaseConfiguration
                )
            ), as: .psql)
    }

    // STR-234 replaces the executable historical chain with the reviewed
    // current-schema baseline. This migration intentionally accepts only a
    // fresh database; see ADR 0009 for the cutover decision.
    app.migrations.add(CurrentSchemaBaseline())

    // STR-28: project-scoped native OVN load balancers, incremental listener
    // and backend membership, external Floating IP attachment, and quota.
    app.migrations.add(CreateLoadBalancer())
    app.migrations.add(CreateLoadBalancerListener())
    app.migrations.add(CreateLoadBalancerBackend())
    app.migrations.add(AddLoadBalancerCountToResourceQuota())

    // STR-236: initialize the previously inert network counter from the
    // project-wide logical networks each global quota actually governs.
    app.migrations.add(BackfillNetworkQuotaAccounting())

    // STR-237: fresh, feature-scoped dependency health becomes the authority
    // for new placement while existing workloads remain untouched.
    app.migrations.add(AddAgentDependencyObservations())

    // STR-64: choose full seed ISO or IMDS-backed NoCloud per VM. Existing
    // rows stay on the full ISO explicitly; this phase does not cut them over.
    app.migrations.add(AddMetadataSourceToVM())

    // Not `app.autoMigrate()` (STR-183). Fluent's migrator takes no lock and
    // wraps no transaction around a migration and the `_fluent_migrations` row
    // that records it, so concurrent replica boots race the same migration and a
    // crash mid-migration leaves a half-state no later boot can get past.
    // `SchemaMigrator` serializes the phase on a Postgres advisory lock and
    // commits each migration with its log row.
    var schemaMigrationOptions = SchemaMigrator.Options.fromEnvironment()
    schemaMigrationOptions.statementTimeouts = databaseStatementTimeouts
    try await SchemaMigrator.run(on: app, options: schemaMigrationOptions)

    // STR-186 prevents new tenant IPv6 subnets from overlapping the ULA space
    // used by metadata and per-network resolvers. Existing rows cannot be
    // renumbered safely in place, so name every collision at each startup until
    // its operator remediates it.
    try await NetworkServiceSpaceAudit.warnAboutCollidingNetworks(on: app.db, logger: app.logger)

    // Reconcile the iam_roles/iam_role_actions tables with the code-side
    // curated registry. Runs every startup so registry changes land with the
    // deploy that carries them.
    try await RoleRegistrySync.sync(on: app.db, logger: app.logger)

    // IAM phase 2: track the policy-set version. Runs after the registry sync
    // so this replica starts from the version that sync may have just written,
    // and before anything can change policy. Under `.testing` the periodic
    // re-read would outlive the test's application, and the tests that care
    // drive the cache directly.
    //
    // IAM phase 3 (#480): the compiled Cedar policy set hangs off the version
    // watch, level-triggered so a failed rebuild retries on the periodic
    // re-read. The listener registers first so the watch's initial refresh
    // performs the boot-time build.
    //
    // Since cutover (#482) the compiled set is the authoritative decision
    // path, so `.testing` needs it too — but built once at boot rather than
    // via the watch, whose periodic re-read would outlive the test's
    // application. Tests that change policy (guardrail writes) drive
    // `cedarPolicySet.reconcile` directly.
    //
    // IAM #610: densify `iam_guardrails.cedar_text` before the set is built, so
    // the compiled set uses the stored text rather than the cache's
    // matcher-regeneration fallback. Idempotent, only touches NULL rows, and
    // needs no version bump (regeneration is byte-identical). Skipped in
    // `.testing`, where the fallback covers any null row and suites that need a
    // dense column write it explicitly.
    if app.environment != .testing {
        try await GuardrailStore.backfillCedarText(on: app.db, logger: app.logger)
    }
    if app.environment != .testing {
        await app.startCedarPolicySetCache()
        await app.startPolicySetVersionWatch()
    } else {
        let version = try await PolicySetVersionService.current(on: app.db)
        await app.cedarPolicySet.rebuild(version: version, on: app.db)
    }

    // Converge any plaintext stored secrets (OIDC client secrets, SSF auth
    // tokens) to encrypted form. Runs every startup (not a one-shot migration)
    // so a key added after upgrade still picks up rows written before it
    // existed. No-op without a key.
    try await secretsEncryption.encryptStoredSecrets(on: app.db, logger: app.logger)

    // Initialize the WebAuthn decoy credential key (generates if not exists),
    // so the first login begin doesn't pay the generate-and-store round trip.
    _ = try await DecoyKeyService.getKey(from: app)

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

    // Guest JWT-SVID issuance is default-off until an operator supplies an
    // explicit audience allowlist.
    try app.configureGuestIdentityIssuance()

    // Configure SVID issuance telemetry for the Workload Identity view
    // (requires SPIRE_METRICS_PROMETHEUS_URL; otherwise the panel stays empty)
    app.configureSPIREIssuanceMetrics()

    // JWT-SVIDs as programmatic credentials (issue #495): registered workloads
    // and service accounts authenticate to the HTTP API with a short-lived
    // bearer token instead of an API key. Opt-in, and needs the SPIRE server
    // API for the trust domain's JWT authorities. Registered after
    // `configureSPIRERegistration` above, which it reads its source from.
    app.configureJWTSVIDAuthentication()

    // The agent service's heartbeat monitor must not outlive the application:
    // the handler cancels it at shutdown (if the service was ever created).
    app.lifecycle.use(AgentServiceLifecycleHandler())

    // Audit retention (issue #39): when AUDIT_RETENTION_DAYS is set, an
    // hourly cluster-singleton sweep prunes audit_events rows older than the
    // cutoff. The handler arms the sweep at boot and cancels it at shutdown.
    app.lifecycle.use(AuditRetentionLifecycleHandler())

    // IAM phase 4 (issue #481): decision-log recording and retention. Resolve
    // the config once here rather than re-reading the environment on every
    // access. Tests override the stored value after `configure` to opt into
    // recording.
    app.iamDecisionLogConfig = .fromEnvironment(app.environment)
    app.lifecycle.use(IAMDecisionLogLifecycleHandler())

    // SSF poll delivery (issue #38): periodically drain poll-delivery streams
    // from their transmitters. The handler arms the sweep at boot and cancels
    // it at shutdown.
    app.lifecycle.use(SSFPollLifecycleHandler())

    // Webhook notifications (issue #559): periodically drain the
    // webhook_deliveries outbox. The handler arms the sweep at boot and
    // cancels it at shutdown.
    app.lifecycle.use(WebhookDeliveryLifecycleHandler())

    // Blue/green drain: flip `/health/ready` to 503 on SIGTERM so a load
    // balancer pulls this replica before Vapor stops accepting connections.
    app.lifecycle.use(DrainSignalLifecycleHandler())

    // `App bootstrap`: seed a first admin + org + project and print an API key
    // once, for deployments that must be driven without a browser (CI, e2e).
    // Registered unconditionally; the command itself refuses if any user exists.
    app.asyncCommands.use(BootstrapCommand(), as: "bootstrap")

    // `App grant-platform-admin`: the break-glass path back in when a
    // deployment has no reachable administrator (STR-178). Seeding the first
    // admin cannot be an authorization decision, so it lives here rather than
    // behind an API — named and documented instead of a hand-written UPDATE.
    app.asyncCommands.use(GrantPlatformAdminCommand(), as: "grant-platform-admin")

    // Open the readiness gate: every migration, schema load, and boot-time
    // backfill above has finished. Vapor binds the port only after `configure`
    // returns, so in the normal path a probe cannot arrive before this line —
    // the gate exists so that stays true if boot work ever moves later, and so
    // "ready" has an explicit meaning rather than an implicit one.
    app.readiness.markMigrationsComplete()

    try routes(app)

    // The structural half of default-deny (#482): every registered route must
    // carry an authorization classification, or the process refuses to start.
    // Runs in every environment, so the whole test suite fails the moment an
    // unclassified endpoint is added.
    try app.assertAllRoutesClassified()
}
