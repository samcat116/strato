import Vapor

extension Application {
    /// Registers long-running work and operator commands after their runtime
    /// dependencies have been installed.
    func bootstrapLifecycle() {
        lifecycle.use(AgentServiceLifecycleHandler())
        lifecycle.use(AuditRetentionLifecycleHandler())

        iamDecisionLogConfig = .fromConfiguration(controlPlaneConfiguration)
        lifecycle.use(IAMDecisionLogLifecycleHandler())
        lifecycle.use(SSFPollLifecycleHandler())
        lifecycle.use(WebhookDeliveryLifecycleHandler())
        lifecycle.use(DrainSignalLifecycleHandler())

        asyncCommands.use(BootstrapCommand(), as: "bootstrap")
        asyncCommands.use(GrantPlatformAdminCommand(), as: "grant-platform-admin")
    }
}
