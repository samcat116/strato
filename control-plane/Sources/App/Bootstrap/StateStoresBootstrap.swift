import Fluent
import Valkey
import Vapor

extension Application {
    /// Installs the durable and coordination stores plus the outbound clients
    /// whose production/test adapters are selected at startup.
    func bootstrapStateStores() throws {
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
        if environment == .testing {
            coordination = CoordinationService(store: InMemoryCoordinationStore(), logger: logger)
            sessions.use(.fluent)
        } else {
            guard let valkeyConfig = ValkeyStoreConfiguration.fromConfiguration(controlPlaneConfiguration) else {
                let error = ValkeyConfigurationError.notConfigured
                logger.critical("\(error.description)")
                throw error
            }
            configureValkey(valkeyConfig)

            // Held on the application as well as handed to the driver, so
            // `/health/ready` can probe session storage without reaching through
            // Vapor's session provider.
            let sessionStore = ValkeySessionStore(client: sessionValkey)
            self.sessionStore = sessionStore
            sessions.use(.valkey(store: sessionStore))

            coordination = CoordinationService(store: ValkeyCoordinationStore(app: self), logger: logger)
            // Fail fast at boot (after the run loops start) if either endpoint is
            // unreachable. Both are fatal: coordination fails open against a runtime
            // blip, but an endpoint that is wrong at boot is a misconfiguration.
            lifecycle.use(ValkeyReachabilityLifecycleHandler(configuration: valkeyConfig))
            logger.info(
                valkeyConfig.sharesOneInstance
                    ? "Using one Valkey endpoint for coordination and session storage"
                    : "Using separate Valkey endpoints for coordination and session storage")
        }
        middleware.use(sessions.middleware)

        // At-rest encryption for recoverable secrets (OIDC client secrets, SSF
        // stream auth tokens). A malformed key fails startup — a typo must not
        // silently downgrade to plaintext storage — while an absent key runs
        // pass-through with a warning so existing deployments keep working until
        // the operator sets one.
        let secretsEncryption = try SecretsEncryptionService.fromConfiguration(controlPlaneConfiguration)
        self.secretsEncryption = secretsEncryption
        if !secretsEncryption.isEnabled {
            logger.warning(
                "STRATO_SECRET_ENCRYPTION_KEY is not set — OIDC client secrets and SSF auth tokens will be stored unencrypted. Generate a key with `openssl rand -hex 32` and set it to enable encryption at rest."
            )
        }

        // Registry client for sandbox tag→digest resolution and pull-token
        // minting (issue #414). Tests get the no-network client so sync assembly
        // never does registry I/O in the suite; tests that exercise the flow
        // install a scripted client of their own.
        registryClient =
            environment == .testing
            ? NoopRegistryClient()
            : DistributionRegistryClient(app: self)

        // Release-artifact resolution for agent updates (issue #432). Tests get a
        // resolver that refuses rather than one that dials the release host, so no
        // suite can depend on github.com being reachable — and a test whose stub
        // never took says so instead of failing as a 404, which is what made the
        // AgentAutoUpdateTests.staleTargetIsReset flake so hard to read. Tests that
        // exercise the flow install a stub of their own.
        agentArtifactResolver =
            environment == .testing
            ? .refusing("The test environment resolves no release artifacts; install a stub resolver in the test.")
            : .releaseHost(app: self)

        // Where image bytes live. Filesystem by default so existing deployments
        // upgrade untouched; IMAGE_STORAGE_BACKEND=s3 moves them to object storage
        // (required on Kubernetes, where the control plane has no persistent
        // volume and replicas don't share one — see docs/architecture/storage.md).
        // Tests install a store directly and must not read the environment here.
        if environment != .testing {
            try ImageObjectStoreFactory.configure(self)
        }
    }
}
