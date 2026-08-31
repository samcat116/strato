import Vapor

extension Application {
    /// Installs runtime modules whose construction depends on migrated and
    /// reconciled database state.
    func bootstrapRuntimeModules() async throws {
        let schedulingStrategy = SchedulingStrategy(
            rawValue: controlPlaneConfiguration.string(.schedulingStrategy)!)!
        useScheduler(SchedulerService(logger: logger, defaultStrategy: schedulingStrategy))
        logger.info("Scheduler service initialized with strategy: \(schedulingStrategy.rawValue)")

        try await configureSPIRE()
        try configureSPIRERegistration()
        try configureGuestIdentityIssuance(configuration: controlPlaneConfiguration)
        configureSPIREIssuanceMetrics()
        configureJWTSVIDAuthentication()
    }
}
