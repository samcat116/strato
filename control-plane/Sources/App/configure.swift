import Fluent
import FluentPostgresDriver
import NIOSSL
import Vapor
import OTel
import Redis

public func configure(_ app: Application) async throws {
    // Configure Valkey if available, fallback to Fluent sessions
    if let valkeyConfig = ValkeyConfiguration.fromEnvironment() {
        do {
            try app.configureValkey(valkeyConfig)
            app.sessions.use(.redis)
            app.logger.info("Using Valkey for session storage")
        } catch {
            app.logger.warning("Valkey configuration failed, using Fluent sessions: \(error)")
            app.sessions.use(.fluent)
        }
    } else {
        app.sessions.use(.fluent)
        app.logger.info("Valkey not configured, using Fluent for session storage")
    }
    app.middleware.use(app.sessions.middleware)

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
    app.migrations.add(AlterSCIMTokenForeignKey())
    app.migrations.add(AddSCIMExternalIDIndex())

    // Image management migrations
    app.migrations.add(CreateImage())
    app.migrations.add(AddImageToVM())

    // App settings migration (for signing keys, etc.)
    app.migrations.add(CreateAppSetting())

    try await app.autoMigrate()

    // Initialize the image download signing key (generates if not exists)
    _ = try await URLSigningService.getSigningKeyAsync(from: app)

    // Dev auth bypass - create dev user for local development
    if app.environment == .development, Environment.get("DEV_AUTH_BYPASS") == "true" {
        app.logger.warning("⚠️ DEV_AUTH_BYPASS enabled - authentication is disabled!")
        let devUser: User
        if let existingUser = try await User.query(on: app.db)
            .filter(\.$username == "dev")
            .first()
        {
            devUser = existingUser
        } else {
            devUser = User(
                username: "dev",
                email: "dev@localhost",
                displayName: "Dev User",
                isSystemAdmin: true
            )
            try await devUser.save(on: app.db)
            app.logger.info("Created dev user for auth bypass")
        }
        // Ensure dev user has a default organization
        let defaultOrg: Organization
        if let existingOrg = try await Organization.query(on: app.db)
            .filter(\.$name == "Default Organization")
            .first()
        {
            defaultOrg = existingOrg
        } else {
            defaultOrg = Organization(
                name: "Default Organization",
                description: "Default organization for development"
            )
            try await defaultOrg.save(on: app.db)
            app.logger.info("Created default organization for dev user")
        }

        // Ensure default project exists for the organization
        let defaultProject: Project
        if let existingProject = try await Project.query(on: app.db)
            .filter(\.$organization.$id == defaultOrg.id!)
            .filter(\.$name == "Default Project")
            .first()
        {
            defaultProject = existingProject
        } else {
            defaultProject = Project(
                name: "Default Project",
                description: "Default project for Default Organization",
                organizationID: defaultOrg.id,
                path: "/\(defaultOrg.id!.uuidString)"
            )
            try await defaultProject.save(on: app.db)

            // Update project path with its own ID
            defaultProject.path = "/\(defaultOrg.id!.uuidString)/\(defaultProject.id!.uuidString)"
            try await defaultProject.save(on: app.db)
            app.logger.info("Created default project for dev organization")
        }

        // Always ensure SpiceDB relationships exist (idempotent)
        // This handles cases where DB state exists but SpiceDB was reset
        try await app.spicedb.writeRelationship(
            entity: "organization",
            entityId: defaultOrg.id!.uuidString,
            relation: "admin",
            subject: "user",
            subjectId: devUser.id!.uuidString
        )

        try await app.spicedb.writeRelationship(
            entity: "project",
            entityId: defaultProject.id!.uuidString,
            relation: "organization",
            subject: "organization",
            subjectId: defaultOrg.id!.uuidString
        )

        // Link dev user to organization if not already linked
        let existingMembership = try await UserOrganization.query(on: app.db)
            .filter(\.$user.$id == devUser.id!)
            .filter(\.$organization.$id == defaultOrg.id!)
            .first()

        if existingMembership == nil {
            let membership = UserOrganization(
                userID: devUser.id!,
                organizationID: defaultOrg.id!,
                role: "admin"
            )
            try await membership.save(on: app.db)
        }

        // Set current organization if not set
        if devUser.currentOrganizationId == nil {
            devUser.currentOrganizationId = defaultOrg.id
            try await devUser.save(on: app.db)
        }

        app.storage[DevUserKey.self] = devUser
    }

    // Configure scheduler service
    // Default strategy can be configured via environment variable
    let schedulingStrategy = Environment.get("SCHEDULING_STRATEGY")
        .flatMap { SchedulingStrategy(rawValue: $0) } ?? .leastLoaded
    app.scheduler = SchedulerService(logger: app.logger, defaultStrategy: schedulingStrategy)
    app.logger.info("Scheduler service initialized with strategy: \(schedulingStrategy.rawValue)")

    // Configure SPIFFE/SPIRE authentication (if enabled via environment)
    try await app.configureSPIRE()

    // Configure OpenTelemetry observability (metrics, logs, traces)
    if app.environment != .testing {
        let metricsEnabled = Environment.get("OTEL_METRICS_ENABLED").flatMap(Bool.init) ?? true
        let logsEnabled = Environment.get("OTEL_LOGS_ENABLED").flatMap(Bool.init) ?? true
        let tracesEnabled = Environment.get("OTEL_TRACES_ENABLED").flatMap(Bool.init) ?? true

        // Only bootstrap OpenTelemetry if at least one feature is enabled
        if metricsEnabled || logsEnabled || tracesEnabled {
            var otelConfig = OTel.Configuration.default
            otelConfig.serviceName = Environment.get("OTEL_SERVICE_NAME") ?? "strato-control-plane"

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

            app.logger.info("Bootstrapping OpenTelemetry", metadata: [
                "service": .string(otelConfig.serviceName),
                "metrics": .stringConvertible(otelConfig.metrics.enabled),
                "logs": .stringConvertible(otelConfig.logs.enabled),
                "traces": .stringConvertible(otelConfig.traces.enabled)
            ])

            let observability = try OTel.bootstrap(configuration: otelConfig)
            app.lifecycle.use(OTelLifecycleHandler(observability: observability))
            app.logger.info("OpenTelemetry observability service registered")
        } else {
            app.logger.info("OpenTelemetry disabled, skipping bootstrap")
        }
    }

    try routes(app)

    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
}
