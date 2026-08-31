import Fluent
import Valkey
import Vapor

extension Application {
    /// Installs durable and coordination stores and selects the production or
    /// test adapters for outbound stateful clients.
    func bootstrapStateStores() throws {
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

            let sessionStore = ValkeySessionStore(client: sessionValkey)
            self.sessionStore = sessionStore
            sessions.use(.valkey(store: sessionStore))

            coordination = CoordinationService(store: ValkeyCoordinationStore(app: self), logger: logger)
            lifecycle.use(ValkeyReachabilityLifecycleHandler(configuration: valkeyConfig))
            logger.info(
                valkeyConfig.sharesOneInstance
                    ? "Using one Valkey endpoint for coordination and session storage"
                    : "Using separate Valkey endpoints for coordination and session storage")
        }
        middleware.use(sessions.middleware)

        let secretsEncryption = try SecretsEncryptionService.fromConfiguration(controlPlaneConfiguration)
        self.secretsEncryption = secretsEncryption
        if !secretsEncryption.isEnabled {
            logger.warning(
                "STRATO_SECRET_ENCRYPTION_KEY is not set — OIDC client secrets and SSF auth tokens will be stored unencrypted. Generate a key with `openssl rand -hex 32` and set it to enable encryption at rest."
            )
        }

        registryClient =
            environment == .testing
            ? NoopRegistryClient()
            : DistributionRegistryClient(app: self)

        agentArtifactResolver =
            environment == .testing
            ? .refusing("The test environment resolves no release artifacts; install a stub resolver in the test.")
            : .releaseHost(app: self)

        if environment != .testing {
            try ImageObjectStoreFactory.configure(self)
        }
    }
}
