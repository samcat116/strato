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

        let metricsEnabled = controlPlaneConfiguration.bool(.otelMetricsEnabled)
        let logsEnabled = controlPlaneConfiguration.bool(.otelLogsEnabled)
        let tracesEnabled = controlPlaneConfiguration.bool(.otelTracesEnabled)

        // Only bootstrap OpenTelemetry if at least one feature is enabled
        guard metricsEnabled || logsEnabled || tracesEnabled else {
            logger.info("OpenTelemetry disabled, skipping bootstrap")
            return
        }

        var otelConfig = OTel.Configuration.default
        otelConfig.serviceName = controlPlaneConfiguration.requiredString(.otelServiceName)

        // Widen the RED duration histogram past 10s. The OTel default top bucket
        // is 10_000ms, so `histogram_quantile` clamps to 10 whenever the quantile
        // lands in `+Inf` — an 11s, a 24s and a 300s request all render as a flat
        // 10s ceiling, which is exactly how the #731 probe stall hid on the
        // "Slowest routes (p95)" panel. Append 30s and 60s so a >10s tail is
        // actually distinguishable. Scoped to this one instrument by label; the
        // internal sub-second timers (placement/authz/sync) keep the default set.
        otelConfig.metrics.durationHistogramBuckets[Telemetry.httpRequestDurationMetric] =
            [5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000, 30000, 60000]
            .map { Duration.milliseconds($0) }

        // Resource attributes stamped on every metric/log/trace so signals
        // are queryable per build, per deployment, and per replica. Combined
        // with anything supplied via OTEL_RESOURCE_ATTRIBUTES.
        // `service.instance.id` uses the coordination replica ID so a metric
        // series or a trace can be tied back to the exact process that emitted
        // it in a multi-replica deployment.
        otelConfig.resourceAttributes["service.version"] = BuildInfo.version(
            configuration: controlPlaneConfiguration)
        otelConfig.resourceAttributes["service.instance.id"] = replicaID
        otelConfig.resourceAttributes["deployment.environment.name"] = environment.name
        let gitSHA = BuildInfo.gitSHA(configuration: controlPlaneConfiguration)
        if gitSHA != "unknown" {
            otelConfig.resourceAttributes["vcs.revision"] = gitSHA
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
