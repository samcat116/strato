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

    // Volume management controller
    try app.register(collection: VolumeController())

    // Console WebSocket controller for VM console streaming
    try app.register(collection: ConsoleWebSocketController())

    // OpenAPI Vapor transport (spec-first). Once the generator produces APIProtocol
    // from Sources/App/openapi.yaml, register handlers here.
    // let transport = VaporTransport(routesBuilder: app)
    // let apiImpl = GeneratedAPIImpl() // conforms to generated protocol
    // try apiImpl.registerHandlers(on: transport)

    // Note: Frontend is now served by a separate Next.js container.
    // SPA catch-all routes have been removed - routing is handled by ingress/nginx.
}
