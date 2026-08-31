import Vapor

extension Application {
    /// Installs runtime modules whose construction depends on the migrated and
    /// reconciled database state.
    func bootstrapRuntimeModules() async throws {
        let schedulingStrategy = controlPlaneConfiguration.schedulingStrategy
        useScheduler(SchedulerService(logger: logger, defaultStrategy: schedulingStrategy))
        logger.info("Scheduler service initialized with strategy: \(schedulingStrategy.rawValue)")

        // Configure SPIFFE/SPIRE authentication when enabled in startup configuration.
        try await configureSPIRE()

        // Configure SPIRE join-token provisioning for the agent registration flow
        // (requires SPIRE_ENABLED plus SPIRE_SERVER_API_ADDRESS).
        try configureSPIRERegistration()

        // Guest JWT-SVID issuance is default-off until an operator supplies an
        // explicit audience allowlist.
        try configureGuestIdentityIssuance(configuration: controlPlaneConfiguration)

        // Configure SVID issuance telemetry for the Workload Identity view
        // (requires SPIRE_METRICS_PROMETHEUS_URL; otherwise the panel stays empty).
        configureSPIREIssuanceMetrics()

        // JWT-SVIDs as programmatic credentials (issue #495): registered workloads
        // and service accounts authenticate to the HTTP API with a short-lived
        // bearer token instead of an API key. Opt-in, and needs the SPIRE server
        // API for the trust domain's JWT authorities. Registered after
        // `configureSPIRERegistration` above, which it reads its source from.
        configureJWTSVIDAuthentication()
    }
}
