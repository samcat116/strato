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

    // How far to trust `X-Forwarded-For`, shared by rate limiting, audit
    // `sourceIP`, and API-key `lastUsedIP` so one request resolves to one
    // address everywhere. Set before any middleware that reads it.
    app.proxyTrust = .fromEnvironment()

    // The shared HTTP client makes server-side fetches to security-sensitive
    // endpoints (OIDC discovery/token/userinfo/JWKS, OCI registry manifests and
    // token realms). Those hosts are validated up front, but a 3xx from a
    // validated host would otherwise let the client silently follow a redirect
    // to an internal address (cloud metadata, loopback, private services),
    // defeating the check — so redirect-following is off by default.
    //
    // Callers that legitimately need redirects follow them explicitly rather
    // than relying on this client: `ImageFetchService` manages its own client
    // and revalidates every hop against `SSRFGuard`, and
    // `AgentUpdateArtifacts` follows the release host's CDN redirect by hand
    // (its base URL is operator-configured, never tenant-supplied). Anything
    // added here that fetches a redirecting host must do likewise.
    app.http.client.configuration.redirectConfiguration = .disallow

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

    // Where image bytes live. Filesystem by default so existing deployments
    // upgrade untouched; IMAGE_STORAGE_BACKEND=s3 moves them to object storage
    // (required on Kubernetes, where the control plane has no persistent
    // volume and replicas don't share one — see docs/architecture/storage.md).
    // Tests install a store directly and must not read the environment here.
    if app.environment != .testing {
        try ImageObjectStoreFactory.configure(app)
    }

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

    // Register the authorization middleware in every environment — including
    // .testing. It used to be skipped under .testing, which meant every controller
    // test ran with authorization off and no test could catch an authz regression
    // (issue #196). Since cutover (#482) authorization is evaluated by the
    // in-process Cedar policy set against real `role_bindings` rows, so tests
    // exercise the exact production decision path — there is no permissive mock
    // in front of it.
    app.middleware.use(AuthorizationMiddleware())

    // Configure database based on environment
    if app.environment == .testing {
        // Testing environment already configured with a per-test Postgres
        // database clone in test setup — skip database configuration here
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

    // Cloud-init user data column. Same ordering constraint as above.
    app.migrations.add(AddUserDataToVM())

    // App settings migration (the WebAuthn decoy credential key, etc.)
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

    // Per-provider SSRF allow-list: hosts the provider's own discovery document
    // named as its token/userinfo/JWKS endpoints, so an IdP serving keys from a
    // second domain (Google) works without editing the global allow-list.
    app.migrations.add(AddDiscoveredHostsToOIDCProvider())

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

    // IAM phase 1 (issue #477): the role_bindings policy store and the
    // role/action registry — the durable state Cedar evaluates.
    app.migrations.add(CreateRoleBinding())
    app.migrations.add(CreateIAMRoleRegistry())

    // IAM phase 2 (issue #479): the forbid-only guardrail store and the
    // policy-set version log that drives compiled-policy-set invalidation.
    app.migrations.add(CreateGuardrail())
    app.migrations.add(CreatePolicySetVersion())

    // IAM phase 4 (issue #481): the authorization decision log.
    app.migrations.add(CreateIAMDecisionLog())

    // Sandbox snapshots / checkpoint-resume (issue #426).
    app.migrations.add(CreateSandboxSnapshot())
    // Sandbox fork lineage (issue #427). Must follow snapshots so deployments
    // see the source table before the feature starts accepting references.
    app.migrations.add(AddSandboxRestoreLineage())
    app.migrations.add(AddSandboxSnapshotGuestControlVersion())
    app.migrations.add(AddSandboxSnapshotForkLayoutVersion())
    // Snapshot mobility (issue #428): the export record + cross-agent
    // compatibility constraints, and the sandbox's create-time CPU template.
    app.migrations.add(AddSandboxSnapshotMobility())

    // Give the seeded "default" network resolvers so guests can resolve names
    // out of the box (issue #518). Runs late: it must follow the migration that
    // adds `dns_servers`, and it only fills a network that still has none.
    app.migrations.add(SeedDefaultNetworkDNS())

    // SPIFFE-only agent enrollment: the new scope/identity record, and the
    // retirement of the bearer-token table it replaces. Ordered after the
    // migrations that shaped that table so the drop lands on a known schema.
    app.migrations.add(CreateAgentEnrollment())
    // Must sit between the two: it reads the token table and writes the
    // enrollment table, so it needs the latter to exist and the former to
    // still be there.
    app.migrations.add(MigratePendingTokensToEnrollments())
    app.migrations.add(DropAgentRegistrationTokens())

    // Floating IPs (issue #344): external address pools + per-address
    // allocations attached to VM NICs. Ordered after sites, projects, and
    // vm_network_interfaces, which it references.
    app.migrations.add(CreateFloatingIP())

    // QEMU guest agent (issue #563): guest-reported addresses per NIC, and the
    // observed hostname / qga-availability on the VM. Ordered after
    // vm_network_interfaces (referenced) and the vms table.
    app.migrations.add(CreateVMInterfaceObservedAddresses())
    app.migrations.add(AddGuestInfoToVM())

    // OAuth device grant for the strato CLI (issue #558): pending device
    // authorizations plus the access/refresh token sessions they mint.
    app.migrations.add(CreateDeviceAuthorization())
    app.migrations.add(CreateCLISession())

    // Give every pre-existing org a default site so it can enroll agents now
    // that enrollment requires one. Ordered after CreateSite and the org
    // tables it reads.
    app.migrations.add(BackfillDefaultSites())

    // FluentKit force-unwraps persisted @Enum raw values on first property
    // access. Normalize casing drift and put a database validation boundary in
    // front of every persisted enum so malformed rows cannot trap the process
    // (issue #527). This stays last because it covers tables added throughout
    // the full migration history.
    app.migrations.add(EnforcePersistedEnumValues())

    // Snapshot export (issue #428) added a `resource_operations.kind` value;
    // deployments whose enum constraints were installed before it must have
    // the constraint re-installed with the extended list. Idempotent on
    // fresh databases. Ordered after EnforcePersistedEnumValues.
    app.migrations.add(AddSnapshotExportOperationKind())

    // virtio-balloon guest memory stats (issue #567).
    app.migrations.add(AddGuestMemoryStatsToVM())

    // CPU/memory hot-add (issue #568): the memory headroom column, and the
    // `resize` operation kind its online path records. Both ordered after
    // EnforcePersistedEnumValues, whose constraint the latter re-installs.
    app.migrations.add(AddMaxMemoryToVM())
    app.migrations.add(AddResizeOperationKind())

    // Operator balloon targets (issue #567 phase 2): the requested guest
    // ceiling and the balloon size actually reached.
    app.migrations.add(AddBalloonTargetToVM())

    // Replace the constant "platform" device type on existing passkeys with the
    // value implied by their backup-eligible flag.
    app.migrations.add(BackfillPasskeyDeviceType())

    // IAM roles/policies authoring phase 1 (issue #604): the unified role
    // store — seeded defaults + user-created roles as rows, role identity by
    // row uuid in role_bindings.
    app.migrations.add(ReplaceIAMRoleRegistry())

    // Windows guest support (issue #565): per-VM Secure Boot / vTPM intent and
    // the agent-side swtpm capability the scheduler gates it on.
    app.migrations.add(AddMachineProfileToVM())

    // Issue #641: `projects.environments` was a JSON-encoded text column purely
    // for SQLite; with Postgres the model uses a native `[String]` field.
    app.migrations.add(ConvertProjectEnvironmentsToArray())

    // Per-org SPIRE trust domains phase 2 (issue #613). Both ship dark: with
    // SPIRE_ORG_TRUST_DOMAINS_ENABLED off nothing writes org_trust_domains
    // rows, and every agent stays in the single platform trust domain.
    app.migrations.add(CreateOrgTrustDomain())
    app.migrations.add(AddTrustDomainToAgentIdentities())

    // IAM workload principals (issue #491): service accounts and the workload
    // registry mapping SPIFFE IDs to registered principals.
    app.migrations.add(CreateServiceAccount())
    app.migrations.add(CreateWorkloadRegistration())

    // IAM authored policies (issue #606): org/project-owned Cedar permit/forbid
    // policies compiled into the policy set beside role permits and guardrails.
    app.migrations.add(CreateIAMPolicy())

    // IAM #610: guardrails store their compiled Cedar forbid as the source of
    // truth (matcher builder or hand-authored), unifying them with roles and
    // authored policies.
    app.migrations.add(AddCedarTextToGuardrail())

    try await app.autoMigrate()

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

    // IAM phase 1: populate role_bindings from the relational mirrors
    // (user_organizations, project_members, project_group_grants). Idempotent,
    // so re-running every boot also repairs any grant a crashed request
    // missed.
    if app.environment != .testing {
        try await RoleBindingBackfill.backfillFromMirrors(app)
    }

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

    // Configure SVID issuance telemetry for the Workload Identity view
    // (requires SPIRE_METRICS_PROMETHEUS_URL; otherwise the panel stays empty)
    app.configureSPIREIssuanceMetrics()

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

    // Blue/green drain: flip `/health/ready` to 503 on SIGTERM so a load
    // balancer pulls this replica before Vapor stops accepting connections.
    app.lifecycle.use(DrainSignalLifecycleHandler())

    // `App bootstrap`: seed a first admin + org + project and print an API key
    // once, for deployments that must be driven without a browser (CI, e2e).
    // Registered unconditionally; the command itself refuses if any user exists.
    app.asyncCommands.use(BootstrapCommand(), as: "bootstrap")

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
