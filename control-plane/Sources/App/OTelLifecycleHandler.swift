import OTel
import ServiceLifecycle
import Vapor

/// Lifecycle handler for OpenTelemetry observability.
/// Manages the startup and shutdown of the OTel service that exports metrics, logs, and traces.
actor OTelLifecycleHandler: LifecycleHandler {
    let observability: any Service
    private var task: Task<Void, any Error>?

    init(observability: some Service) {
        self.observability = observability
    }

    /// Called when the Vapor application finishes booting.
    /// Starts the OTel service in a background task.
    public func didBootAsync(_ application: Application) async throws {
        application.logger.info("Starting OpenTelemetry observability service")
        task = Task {
            try await observability.run()
        }
    }

    /// Called when the Vapor application is shutting down.
    /// Cancels the OTel background task.
    func shutdownAsync(_ application: Application) async {
        application.logger.info("Shutting down OpenTelemetry observability service")
        task?.cancel()
    }
}
