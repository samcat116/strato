import Fluent
import FluentPostgresDriver
import ElementaryHTMX
import NIOSSL
import Vapor

// configures your application
public func configure(_ app: Application) async throws {
    // Debug middleware to trace all requests (commented out for production)
    // struct DebugMiddleware: AsyncMiddleware {
    //     func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
    //         print("🔍 DEBUG: Incoming request to \(request.url.path)")
    //         return try await next.respond(to: request)
    //     }
    // }
    // app.middleware.use(DebugMiddleware())

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


    try await app.autoMigrate()

    // register routes
    try routes(app)

    // Debug: Print all registered routes (commented out for production)
    // print("🔍 DEBUG: Registered routes:")
    // for route in app.routes.all {
    //     print("🔍   \(route.method) \(route.path)")
    // }

    // Static files middleware after routes
    // Skip TailwindCSS setup during testing
    if app.environment != .testing {
        try await tailwind(app)
    }
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
}
