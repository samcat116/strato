import Fluent
import FluentPostgresDriver
import ElementaryHTMX
import NIOSSL
import Vapor

// Storage key for certificate maintenance service
struct CertificateMaintenanceServiceKey: StorageKey {
    typealias Value = CertificateMaintenanceService
}

public func configure(_ app: Application) async throws {
    // Configure sessions
    app.middleware.use(app.sessions.middleware)
    app.sessions.use(.fluent)

    // Configure user authentication with sessions
    app.middleware.use(User.sessionAuthenticator())

    // Configure API key authentication (for Bearer tokens)
    app.middleware.use(BearerAuthorizationHeaderAuthenticator())
    
    // Configure certificate-based authentication for agents
    app.middleware.use(AgentCertificateAuthMiddleware())

    // Configure WebAuthn
    let relyingPartyID = Environment.get("WEBAUTHN_RELYING_PARTY_ID") ?? "localhost"
    let relyingPartyName = Environment.get("WEBAUTHN_RELYING_PARTY_NAME") ?? "Strato"
    let relyingPartyOrigin = Environment.get("WEBAUTHN_RELYING_PARTY_ORIGIN") ?? "http://localhost:8080"

    app.configureWebAuthn(
        relyingPartyID: relyingPartyID,
        relyingPartyName: relyingPartyName,
        relyingPartyOrigin: relyingPartyOrigin
    )

    // Add SpiceDB authorization middleware AFTER session middleware
    // Skip SpiceDB in testing environment
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
    
    // Certificate management migrations
    app.migrations.add(CreateCertificateAuthority())
    app.migrations.add(CreateAgentCertificate())
    app.migrations.add(CreateCertificateAuditEvent())

    try await app.autoMigrate()

    // Start certificate maintenance service
    if app.environment != .testing {
        let maintenanceService = CertificateMaintenanceService(
            database: app.db,
            logger: app.logger
        )
        await maintenanceService.startMaintenance()
        
        // Store service in application storage for cleanup
        app.storage[CertificateMaintenanceServiceKey.self] = maintenanceService
    }

    try routes(app)

    if app.environment != .testing {
        try await tailwind(app)
    }
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
}
