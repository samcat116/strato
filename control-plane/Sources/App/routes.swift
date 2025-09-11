import Elementary
import ElementaryHTMX
import Fluent
import Vapor

func routes(_ app: Application) throws {
    // Public routes
    app.get("") { req async throws -> Response in
        req.logger.info("Root route accessed - checking authentication")

        // Check if user is authenticated
        if let user = req.auth.get(User.self) {
            req.logger.info("User is authenticated, checking onboarding status")

            // If user is system admin and has no organizations, redirect to onboarding
            if user.isSystemAdmin {
                try await user.$organizations.load(on: req.db)
                if user.organizations.isEmpty {
                    req.logger.info("System admin needs to complete onboarding")
                    throw Abort.redirect(to: "/onboarding")
                }
            }

            req.logger.info("Rendering dashboard")
            let html = DashboardTemplate().render()
            return Response(
                status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]),
                body: .init(string: html))
        } else {
            // Check if this is a fresh instance (no users exist)
            let isFirstInstance = try await User.isFirstUser(on: req.db)
            if isFirstInstance {
                req.logger.info("Fresh instance - redirecting to register")
                throw Abort.redirect(to: "/register")
            } else {
                req.logger.info("User not authenticated, redirecting to login")
                throw Abort.redirect(to: "/login")
            }
        }
    }

    // Dashboard route (same as root but explicit)
    app.get("dashboard") { req async throws -> Response in
        req.logger.info("Dashboard route accessed - checking authentication")

        // Check if user is authenticated
        if let user = req.auth.get(User.self) {
            req.logger.info("User is authenticated, checking onboarding status")

            // If user is system admin and has no organizations, redirect to onboarding
            if user.isSystemAdmin {
                try await user.$organizations.load(on: req.db)
                if user.organizations.isEmpty {
                    req.logger.info("System admin needs to complete onboarding")
                    throw Abort.redirect(to: "/onboarding")
                }
            }

            req.logger.info("Rendering dashboard")
            let html = DashboardTemplate().render()
            return Response(
                status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]),
                body: .init(string: html))
        } else {
            // Check if this is a fresh instance (no users exist)
            let isFirstInstance = try await User.isFirstUser(on: req.db)
            if isFirstInstance {
                req.logger.info("Fresh instance - redirecting to register")
                throw Abort.redirect(to: "/register")
            } else {
                req.logger.info("User not authenticated, redirecting to login")
                throw Abort.redirect(to: "/login")
            }
        }
    }

    app.get("hello") { _ async -> String in
        "Hello, world!"
    }

    // Authentication views
    app.get("login") { req async throws -> Response in
        // Fetch all enabled OIDC providers from all organizations
        let oidcProviders = try await OIDCProvider.query(on: req.db)
            .filter(\.$enabled == true)
            .with(\.$organization)
            .all()

        let providerInfos: [OIDCProviderInfo] = oidcProviders.compactMap { provider in
            guard let providerID = provider.id,
                  let organizationID = provider.organization.id else {
                return nil
            }
            return OIDCProviderInfo(
                providerID: providerID,
                providerName: provider.name,
                organizationID: organizationID,
                organizationName: provider.organization.name
            )
        }

        let html = LoginTemplate(oidcProviders: providerInfos).render()
        return Response(status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]), body: .init(string: html))
    }

    app.get("register") { _ -> Response in
        let html = RegisterTemplate().render()
        return Response(status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]), body: .init(string: html))
    }

    // Register controllers
    try app.register(collection: HealthController())
    try app.register(collection: UserController())
    try app.register(collection: VMController())
    try app.register(collection: OrganizationController())
    try app.register(collection: APIKeyController())
    try app.register(collection: APIDocumentationController())
    try app.register(collection: AgentWebSocketController())
    try app.register(collection: AgentEnrollmentController())
    try app.register(collection: SecurityController())
    try app.register(collection: OnboardingController())
    try app.register(collection: HTMXController())

    // Hierarchical IAM controllers
    try app.register(collection: OrganizationalUnitController())
    try app.register(collection: ProjectController())
    try app.register(collection: ResourceQuotaController())
    try app.register(collection: HierarchyController())

    // Groups controller
    try app.register(collection: GroupController())

    // OIDC controller
    try app.register(collection: OIDCController())
    // Agent management controller
    try app.register(collection: AgentController())

    // OpenAPI Vapor transport (spec-first). Once the generator produces APIProtocol
    // from Sources/App/openapi.yaml, register handlers here.
    // let transport = VaporTransport(routesBuilder: app)
    // let apiImpl = GeneratedAPIImpl() // conforms to generated protocol
    // try apiImpl.registerHandlers(on: transport)
}
