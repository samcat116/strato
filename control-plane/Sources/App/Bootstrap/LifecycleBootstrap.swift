import ControlPlanePostgres
import Vapor

extension Application {
    /// Registers background loops and shutdown behavior after their runtime
    /// dependencies have been installed, plus operator commands that are
    /// available for the lifetime of the process.
    func bootstrapLifecycle(persistence: ControlPlanePersistence) {
        registerLifecycleHandlers()
        registerCommands(persistence: persistence)
    }

    private func registerLifecycleHandlers() {
        // The agent service's heartbeat monitor must not outlive the application:
        // the handler cancels it at shutdown (if the service was ever created).
        lifecycle.use(AgentServiceLifecycleHandler())

        // Audit retention (issue #39): when AUDIT_RETENTION_DAYS is set, an
        // hourly cluster-singleton sweep prunes audit_events rows older than the
        // cutoff. The handler arms the sweep at boot and cancels it at shutdown.
        lifecycle.use(AuditRetentionLifecycleHandler())

        // IAM phase 4 (issue #481): decision-log recording and retention. Resolve
        // the config once here rather than re-reading the environment on every
        // access. Tests override the stored value after `configure` to opt into
        // recording.
        iamDecisionLogConfig = .fromConfiguration(controlPlaneConfiguration)
        lifecycle.use(IAMDecisionLogLifecycleHandler())

        // SSF poll delivery (issue #38): periodically drain poll-delivery streams
        // from their transmitters. The handler arms the sweep at boot and cancels
        // it at shutdown.
        lifecycle.use(SSFPollLifecycleHandler())

        // Webhook notifications (issue #559): periodically drain the
        // webhook_deliveries outbox. The handler arms the sweep at boot and
        // cancels it at shutdown.
        lifecycle.use(WebhookDeliveryLifecycleHandler())

        // Blue/green drain: flip `/health/ready` to 503 on SIGTERM so a load
        // balancer pulls this replica before Vapor stops accepting connections.
        lifecycle.use(DrainSignalLifecycleHandler())
    }

    private func registerCommands(persistence: ControlPlanePersistence) {
        // `App bootstrap`: seed a first admin + org + project and print an API key
        // once, for deployments that must be driven without a browser (CI, e2e).
        // Registered unconditionally; the command itself refuses if any user exists.
        asyncCommands.use(
            BootstrapCommand(persistence: persistence.bootstrap),
            as: "bootstrap")

        // `App grant-platform-admin`: the break-glass path back in when a
        // deployment has no reachable administrator (STR-178). Seeding the first
        // admin cannot be an authorization decision, so it lives here rather than
        // behind an API — named and documented instead of a hand-written UPDATE.
        asyncCommands.use(GrantPlatformAdminCommand(), as: "grant-platform-admin")
    }
}
