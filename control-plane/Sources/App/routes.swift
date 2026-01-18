import Fluent
import Vapor

func routes(_ app: Application) throws {
    app.get("hello") { _ async -> String in
        "Hello, world!"
    }

    // Register controllers
    try app.register(collection: HealthController())
    try app.register(collection: UserController())
    try app.register(collection: VMController())
    try app.register(collection: OrganizationController())
    try app.register(collection: APIKeyController())
    try app.register(collection: APIDocumentationController())
    try app.register(collection: AgentWebSocketController())
    try app.register(collection: OnboardingController())

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

    // SCIM controllers
    try app.register(collection: SCIMController())
    try app.register(collection: SCIMTokenController())

    // Image management controller
    try app.register(collection: ImageController())

    // Console WebSocket controller for VM console streaming
    try app.register(collection: ConsoleWebSocketController())

    // OpenAPI Vapor transport (spec-first). Once the generator produces APIProtocol
    // from Sources/App/openapi.yaml, register handlers here.
    // let transport = VaporTransport(routesBuilder: app)
    // let apiImpl = GeneratedAPIImpl() // conforms to generated protocol
    // try apiImpl.registerHandlers(on: transport)

    // SPA catch-all route for Next.js static export
    // This serves index.html for all frontend routes, allowing client-side routing
    // FileMiddleware already handles static assets (_next/*, images, etc.)

    // Handle root path (** doesn't match /)
    app.get { req async throws -> Response in
        let indexPath = app.directory.publicDirectory + "index.html"
        req.logger.info("Serving index.html from: \(indexPath)")
        let response = try await req.fileio.asyncStreamFile(at: indexPath)
        req.logger.info("Response status: \(response.status)")
        return response
    }

    app.get("**") { req async throws -> Response in
        let path = req.url.path

        // Skip paths that are handled by API controllers
        let apiPrefixes = ["/api/", "/auth/", "/agent/", "/health"]
        for prefix in apiPrefixes {
            if path.hasPrefix(prefix) {
                throw Abort(.notFound)
            }
        }

        // Return 404 for static asset paths that weren't found by FileMiddleware
        // This prevents serving index.html for missing .js, .css, etc. files
        let staticExtensions = [".js", ".css", ".json", ".map", ".woff", ".woff2", ".svg", ".png", ".jpg", ".ico", ".txt"]
        for ext in staticExtensions {
            if path.hasSuffix(ext) {
                throw Abort(.notFound)
            }
        }

        // Serve index.html for SPA routing
        let indexPath = app.directory.publicDirectory + "index.html"
        return try await req.fileio.asyncStreamFile(at: indexPath)
    }
}
