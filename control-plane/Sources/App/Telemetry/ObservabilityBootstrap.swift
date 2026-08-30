import Logging
import Metrics
import OTel
import ServiceLifecycle
import Tracing
import Vapor

/// The enabled signals and resulting process log sinks resolved before any
/// process-global observability facade is bootstrapped.
struct ObservabilitySignalPlan: Equatable, Sendable {
    enum LogSink: Equatable, Sendable {
        case console
        case otlp
    }

    let metricsEnabled: Bool
    let logsEnabled: Bool
    let tracesEnabled: Bool

    var logSinks: [LogSink] {
        logsEnabled ? [.console, .otlp] : [.console]
    }

    var hasEnabledOTelSignal: Bool {
        metricsEnabled || logsEnabled || tracesEnabled
    }
}

/// The OTLP log handler and its background exporter service. Creating this
/// value does not mutate swift-log's process-global state.
struct PreparedOTelLoggingBackend {
    let factory: @Sendable (String) -> any LogHandler
    let service: any Service
}

/// Everything that must be decided before `Application.make` constructs its
/// logger. Metrics and tracing are installed later, but still before any
/// instrumented client captures their process-global facades.
struct PreparedControlPlaneObservability {
    let plan: ObservabilitySignalPlan
    let configuration: OTel.Configuration
    let loggingBackend: PreparedOTelLoggingBackend?

    static func prepare(
        controlPlaneConfiguration: ControlPlaneConfiguration,
        environment: Environment,
        replicaID: String
    ) throws -> Self {
        let plan = ObservabilityBootstrap.plan(for: controlPlaneConfiguration)
        let configuration = ObservabilityBootstrap.makeOTelConfiguration(
            controlPlaneConfiguration: controlPlaneConfiguration,
            environment: environment,
            replicaID: replicaID)
        let loggingBackend: PreparedOTelLoggingBackend?
        if plan.logsEnabled {
            let backend = try OTel.makeLoggingBackend(configuration: configuration)
            loggingBackend = PreparedOTelLoggingBackend(
                factory: backend.factory,
                service: backend.service)
        } else {
            loggingBackend = nil
        }

        return Self(
            plan: plan,
            configuration: configuration,
            loggingBackend: loggingBackend)
    }

    /// Bootstrap swift-log exactly once with the console sink and, when
    /// enabled, the already-created OTLP backend.
    func bootstrapLogging(from environment: inout Environment) throws {
        let terminal = Terminal()
        let metadataProvider = OTel.makeLoggingMetadataProvider()
        let otelFactory = loggingBackend?.factory

        try LoggingSystem.bootstrap(from: &environment) { level in
            { label in
                let console = ConsoleLogger(
                    label: label,
                    console: terminal,
                    level: level,
                    metadataProvider: metadataProvider)
                let otel = otelFactory?(label)
                return ObservabilityBootstrap.composeLogHandlers(
                    console: console,
                    otel: otel)
            }
        }
    }
}

enum ObservabilityBootstrap {
    enum Error: Swift.Error, CustomStringConvertible {
        case loggingWasNotPrepared

        var description: String {
            switch self {
            case .loggingWasNotPrepared:
                "Non-test startup must prepare logging before Application.make"
            }
        }
    }

    static func plan(for configuration: ControlPlaneConfiguration) -> ObservabilitySignalPlan {
        ObservabilitySignalPlan(
            metricsEnabled: configuration.bool(.otelMetricsEnabled)!,
            logsEnabled: configuration.bool(.otelLogsEnabled)!,
            tracesEnabled: configuration.bool(.otelTracesEnabled)!)
    }

    static func composeLogHandlers(
        console: any LogHandler,
        otel: (any LogHandler)?
    ) -> any LogHandler {
        guard let otel else { return console }
        return MultiplexLogHandler([console, otel])
    }

    static func makeOTelConfiguration(
        controlPlaneConfiguration: ControlPlaneConfiguration,
        environment: Environment,
        replicaID: String
    ) -> OTel.Configuration {
        let plan = plan(for: controlPlaneConfiguration)
        var configuration = OTel.Configuration.default
        configuration.serviceName = controlPlaneConfiguration.string(.otelServiceName)!

        // Widen the RED duration histogram past 10s. The OTel default top bucket
        // is 10_000ms, so `histogram_quantile` clamps to 10 whenever the quantile
        // lands in `+Inf` — an 11s, a 24s and a 300s request all render as a flat
        // 10s ceiling, which is exactly how the #731 probe stall hid on the
        // "Slowest routes (p95)" panel. Append 30s and 60s so a >10s tail is
        // actually distinguishable. Scoped to this one instrument by label; the
        // internal sub-second timers (placement/authz/sync) keep the default set.
        configuration.metrics.durationHistogramBuckets[Telemetry.httpRequestDurationMetric] =
            [5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000, 30000, 60000]
            .map { Duration.milliseconds($0) }

        // Resource attributes stamped on every metric/log/trace so signals
        // are queryable per build, per deployment, and per replica. Combined
        // with anything supplied via OTEL_RESOURCE_ATTRIBUTES.
        configuration.resourceAttributes["service.version"] = BuildInfo.version(
            configuration: controlPlaneConfiguration)
        configuration.resourceAttributes["service.instance.id"] = replicaID
        configuration.resourceAttributes["deployment.environment.name"] = environment.name
        let gitSHA = BuildInfo.gitSHA(configuration: controlPlaneConfiguration)
        if gitSHA != "unknown" {
            configuration.resourceAttributes["vcs.revision"] = gitSHA
        }

        configuration.metrics.enabled = plan.metricsEnabled
        configuration.logs.enabled = plan.logsEnabled
        configuration.traces.enabled = plan.tracesEnabled

        // Configure OTLP exporter protocol (defaults to gRPC on port 4317).
        // The endpoint can be overridden with OTEL_EXPORTER_OTLP_ENDPOINT.
        #if os(macOS)
        if #available(macOS 15, *) {
            configuration.metrics.otlpExporter.protocol = .grpc
            configuration.logs.otlpExporter.protocol = .grpc
            configuration.traces.otlpExporter.protocol = .grpc
        }
        #else
        configuration.metrics.otlpExporter.protocol = .grpc
        configuration.logs.otlpExporter.protocol = .grpc
        configuration.traces.otlpExporter.protocol = .grpc
        #endif

        return configuration
    }
}

extension Application {
    /// Install the metrics and tracing backends before any instrumented client
    /// captures their facades, then register one lifecycle group containing
    /// every enabled OTLP exporter (including the pre-created logging exporter).
    func bootstrapObservability(_ prepared: PreparedControlPlaneObservability?) throws {
        // Tests never export telemetry: the facades stay on their no-op
        // backends, and `LoggingSystem` keeps the handler the test harness set.
        guard environment != .testing else { return }
        guard let prepared else {
            throw ObservabilityBootstrap.Error.loggingWasNotPrepared
        }

        guard prepared.plan.hasEnabledOTelSignal else {
            logger.info("OpenTelemetry disabled, using console logging only")
            return
        }

        logger.info(
            "Bootstrapping OpenTelemetry",
            metadata: [
                "service": .string(prepared.configuration.serviceName),
                "metrics": .stringConvertible(prepared.plan.metricsEnabled),
                "logs": .stringConvertible(prepared.plan.logsEnabled),
                "traces": .stringConvertible(prepared.plan.tracesEnabled),
            ])

        var services: [any ServiceLifecycle.Service] = []
        if let loggingService = prepared.loggingBackend?.service {
            services.append(loggingService)
        }
        if prepared.plan.metricsEnabled {
            let backend = try OTel.makeMetricsBackend(configuration: prepared.configuration)
            MetricsSystem.bootstrap(backend.factory)
            services.append(backend.service)
        }
        if prepared.plan.tracesEnabled {
            let backend = try OTel.makeTracingBackend(configuration: prepared.configuration)
            InstrumentationSystem.bootstrap(backend.factory)
            services.append(backend.service)
        }

        let observability = ServiceGroup(services: services, logger: logger)
        lifecycle.use(OTelLifecycleHandler(observability: observability))
        logger.info("OpenTelemetry observability service registered")
    }
}
