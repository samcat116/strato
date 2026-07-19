import Fluent
import Vapor

func routes(_ app: Application) throws {
    // Register controllers
    try app.register(collection: HealthController())
    try app.register(collection: UserController())
    try app.register(collection: VMController())
    // Sandboxes: OCI-image Firecracker microVMs (issue #413)
    try app.register(collection: SandboxController())
    try app.register(collection: OperationController())
    try app.register(collection: OrganizationController())
    try app.register(collection: AuthorizationController())
    // IAM tier-2 guardrails + policy-set versioning (issue #479)
    try app.register(collection: GuardrailController())
    try app.register(collection: APIKeyController())
    try app.register(collection: APIDocumentationController())
    try app.register(collection: AgentWebSocketController())

    // Hierarchical IAM controllers
    try app.register(collection: OrganizationalUnitController())
    try app.register(collection: ProjectController())
    try app.register(collection: ProjectMemberController())
    // Registry pull secrets for private sandbox images (issue #414)
    try app.register(collection: RegistryPullSecretController())
    try app.register(collection: ResourceQuotaController())
    try app.register(collection: HierarchyController())

    // Groups controller
    try app.register(collection: GroupController())

    // OIDC controller
    try app.register(collection: OIDCController())
    // Agent management controller
    try app.register(collection: AgentController())
    // Sites (availability zones) grouping agents into shared OVN deployments
    try app.register(collection: SiteController())

    // SCIM controllers
    try app.register(collection: SCIMController())
    try app.register(collection: SCIMTokenController())

    // Shared Signals Framework receiver (issue #38)
    try app.register(collection: SSFStreamController())

    // Image management controller
    try app.register(collection: ImageController())

    // Volume management controller
    try app.register(collection: VolumeController())

    // Network management controller
    try app.register(collection: NetworkController())

    // Console WebSocket controller for VM console streaming
    try app.register(collection: ConsoleWebSocketController())

    // Sandbox exec attach WebSocket (issue #423)
    try app.register(collection: SandboxExecWebSocketController())

    // VM Logs controller for querying logs from Loki
    try app.register(collection: LogsController())

    // Audit trail query API (issue #39)
    try app.register(collection: AuditEventController())

    // Workload Identity (SPIFFE / SPIRE) read API
    try app.register(collection: WorkloadIdentityController())

    // OpenAPI Vapor transport (spec-first). Once the generator produces APIProtocol
    // from Sources/App/openapi.yaml, register handlers here.
    // let transport = VaporTransport(routesBuilder: app)
    // let apiImpl = GeneratedAPIImpl() // conforms to generated protocol
    // try apiImpl.registerHandlers(on: transport)

    // The frontend is served by the separate Next.js container; ingress owns
    // user-facing page routing.
}
