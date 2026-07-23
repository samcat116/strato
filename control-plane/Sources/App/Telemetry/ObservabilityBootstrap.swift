import OTel
import Vapor

extension Application {
    /// Install the OpenTelemetry backends behind the metrics/logging/tracing
    /// facades and register the exporter service with the app lifecycle.
    ///
    /// **This must run before any client library that captures a tracer.**
    /// Instrumented clients read `InstrumentationSystem.tracer` *eagerly*, when
    /// their configuration value is constructed, not per request:
    ///
    /// - `HTTPClient.Configuration.TracingConfiguration.init()` stores
    ///   `InstrumentationSystem.tracer`, so merely reading
    ///   `app.http.client.configuration` materializes a config that has already
    ///   latched a tracer — and Vapor builds the shared client from it later.
    /// - `ValkeyTracingConfiguration.tracer` defaults the same way, latched when
    ///   `ValkeyClientConfiguration` is constructed in `configureValkey`.
    ///
    /// Whatever tracer is in place at that moment is the tracer those clients
    /// use for the life of the process. Bootstrapping afterwards left both
    /// holding the `NoOpTracer`, which is why Valkey command spans and outbound
    /// HTTP spans never reached the backend even though both libraries ship
    /// instrumentation. See `docs/deployment/observability.md`.
    ///
    /// Resource attributes read `replicaID` (lazily generated on first access)
    /// and `environment` (fixed at `Application.make`), so nothing in `configure`
    /// needs to precede this call.
    func bootstrapObservability() throws {
        // Tests never export telemetry: the facades stay on their no-op
        // backends, and `LoggingSystem` keeps the handler the test harness set.
        guard environment != .testing else { return }

        let metricsEnabled = Environment.get("OTEL_METRICS_ENABLED").flatMap(Bool.init) ?? true
        let logsEnabled = Environment.get("OTEL_LOGS_ENABLED").flatMap(Bool.init) ?? true
        let tracesEnabled = Environment.get("OTEL_TRACES_ENABLED").flatMap(Bool.init) ?? true

        // Only bootstrap OpenTelemetry if at least one feature is enabled
        guard metricsEnabled || logsEnabled || tracesEnabled else {
            logger.info("OpenTelemetry disabled, skipping bootstrap")
            return
        }

        var otelConfig = OTel.Configuration.default
        otelConfig.serviceName = Environment.get("OTEL_SERVICE_NAME") ?? "strato-control-plane"

        // Resource attributes stamped on every metric/log/trace so signals
        // are queryable per build, per deployment, and per replica. Combined
        // with anything supplied via OTEL_RESOURCE_ATTRIBUTES.
        // `service.instance.id` uses the coordination replica ID so a metric
        // series or a trace can be tied back to the exact process that emitted
        // it in a multi-replica deployment.
        otelConfig.resourceAttributes["service.version"] = BuildInfo.version
        otelConfig.resourceAttributes["service.instance.id"] = replicaID
        otelConfig.resourceAttributes["deployment.environment.name"] = environment.name
        if BuildInfo.gitSHA != "unknown" {
            otelConfig.resourceAttributes["vcs.revision"] = BuildInfo.gitSHA
        }

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

        logger.info(
            "Bootstrapping OpenTelemetry",
            metadata: [
                "service": .string(otelConfig.serviceName),
                "metrics": .stringConvertible(otelConfig.metrics.enabled),
                "logs": .stringConvertible(otelConfig.logs.enabled),
                "traces": .stringConvertible(otelConfig.traces.enabled),
            ])

        let observability = try OTel.bootstrap(configuration: otelConfig)
        lifecycle.use(OTelLifecycleHandler(observability: observability))
        logger.info("OpenTelemetry observability service registered")
    }
}
