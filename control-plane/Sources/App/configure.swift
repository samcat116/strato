import Fluent
import FluentPostgresDriver
import ElementaryHTMX
import NIOSSL
import Vapor
import OTel

public func configure(_ app: Application) async throws {
    // Configure sessions
    app.middleware.use(app.sessions.middleware)
    app.sessions.use(.fluent)

    // Configure user authentication with sessions
    app.middleware.use(User.sessionAuthenticator())

    // Configure API key authentication (for Bearer tokens)
    app.middleware.use(BearerAuthorizationHeaderAuthenticator())

    // Configure WebAuthn
    let relyingPartyID = Environment.get("WEBAUTHN_RELYING_PARTY_ID") ?? "localhost"
    let relyingPartyName = Environment.get("WEBAUTHN_RELYING_PARTY_NAME") ?? "Strato"
    let relyingPartyOrigin = Environment.get("WEBAUTHN_RELYING_PARTY_ORIGIN") ?? "http://localhost:8080"

    app.configureWebAuthn(
        relyingPartyID: relyingPartyID,
        relyingPartyName: relyingPartyName,
        relyingPartyOrigin: relyingPartyOrigin
    )


    if app.environment != .testing {
        app.middleware.use(SpiceDBAuthMiddleware())
    }

    // Configure database based on environment
    if app.environment == .testing {
        // Testing environment already configured with in-memory SQLite in test setup
        // Skip database configuration here
    } else {
        app.databases.use(
            DatabaseConfigurationFactory.postgres(
                configuration: .init(
                    hostname: Environment.get("DATABASE_HOST") ?? "localhost",
                    port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:))
                        ?? SQLPostgresConfiguration.ianaPortNumber,
                    username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
                    password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
                    database: Environment.get("DATABASE_NAME") ?? "vapor_database",
                tls: .disable)
        ), as: .psql)
    }

    app.migrations.add(CreateUser())
    app.migrations.add(CreateVM())
    app.migrations.add(CreateOrganization())
    app.migrations.add(AddCurrentOrganizationToUser())
    app.migrations.add(CreateAPIKey())
    app.migrations.add(SessionRecord.migration)
    app.migrations.add(EnhanceVM())
    app.migrations.add(FixVMColumnNames())
    app.migrations.add(CreateVMTemplate())
    app.migrations.add(SeedVMTemplates())
    app.migrations.add(AddSystemAdminToUser())

    // Hierarchical IAM migrations
    app.migrations.add(CreateOrganizationalUnit())
    app.migrations.add(CreateProject())
    app.migrations.add(CreateResourceQuota())
    app.migrations.add(AddProjectToVM())
    app.migrations.add(MigrateExistingDataToProjects())
    app.migrations.add(MakeProjectRequiredOnVM())

    // Groups migrations
    app.migrations.add(CreateGroup())
    app.migrations.add(CreateUserGroup())

    // OIDC migrations
    app.migrations.add(CreateOIDCProvider())
    app.migrations.add(AddOIDCFieldsToUser())
    // Agent migrations
    app.migrations.add(CreateAgent())
    app.migrations.add(CreateAgentRegistrationToken())

    // SCIM migrations
    app.migrations.add(CreateSCIMToken())
    app.migrations.add(CreateSCIMExternalID())
    app.migrations.add(AddSCIMFieldsToUser())
    app.migrations.add(AddSCIMFieldsToGroup())

    try await app.autoMigrate()

    // Configure scheduler service
    // Default strategy can be configured via environment variable
    let schedulingStrategy = Environment.get("SCHEDULING_STRATEGY")
        .flatMap { SchedulingStrategy(rawValue: $0) } ?? .leastLoaded
    app.scheduler = SchedulerService(logger: app.logger, defaultStrategy: schedulingStrategy)
    app.logger.info("Scheduler service initialized with strategy: \(schedulingStrategy.rawValue)")

    // Configure OpenTelemetry observability (metrics, logs, traces)
    if app.environment != .testing {
        var otelConfig = OTel.Configuration.default
        otelConfig.serviceName = Environment.get("OTEL_SERVICE_NAME") ?? "strato-control-plane"

        // Enable all three pillars of observability
        otelConfig.metrics.enabled = Environment.get("OTEL_METRICS_ENABLED").flatMap(Bool.init) ?? true
        otelConfig.logs.enabled = Environment.get("OTEL_LOGS_ENABLED").flatMap(Bool.init) ?? true
        otelConfig.traces.enabled = Environment.get("OTEL_TRACES_ENABLED").flatMap(Bool.init) ?? true

        // Configure OTLP exporter protocol (defaults to gRPC on port 4317)
        // Can be overridden with OTEL_EXPORTER_OTLP_ENDPOINT environment variable
        if #available(macOS 15, *) {
            otelConfig.metrics.otlpExporter.protocol = .grpc
            otelConfig.logs.otlpExporter.protocol = .grpc
            otelConfig.traces.otlpExporter.protocol = .grpc
        }

        app.logger.info("Bootstrapping OpenTelemetry", metadata: [
            "service": .string(otelConfig.serviceName),
            "metrics": .stringConvertible(otelConfig.metrics.enabled),
            "logs": .stringConvertible(otelConfig.logs.enabled),
            "traces": .stringConvertible(otelConfig.traces.enabled)
        ])

        let observability = try OTel.bootstrap(configuration: otelConfig)
        app.lifecycle.use(OTelLifecycleHandler(observability: observability))
        app.logger.info("OpenTelemetry observability service registered")
    }

    try routes(app)

    if app.environment != .testing {
        try await tailwind(app)
    }
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
}
