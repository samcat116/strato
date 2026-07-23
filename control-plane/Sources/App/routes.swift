import Fluent
import Vapor

func routes(_ app: Application) throws {
    // Register controllers
    try app.register(collection: HealthController())
    try app.register(collection: UserController())
    // Self-service passkey management for the signed-in user
    try app.register(collection: PasskeyController())
    try app.register(collection: VMController())
    // Sandboxes: OCI-image Firecracker microVMs (issue #413)
    try app.register(collection: SandboxController())
    try app.register(collection: OperationController())
    try app.register(collection: OrganizationController())
    try app.register(collection: AuthorizationController())
    // IAM tier-2 guardrails + policy-set versioning (issue #479)
    try app.register(collection: GuardrailController())
    // IAM role definitions + the action catalog (issue #605)
    try app.register(collection: RoleController())
    // IAM authored Cedar policies (issue #606)
    try app.register(collection: PolicyController())
    // IAM authorization decision logs (issue #481)
    try app.register(collection: IAMDecisionLogController())
    try app.register(collection: APIKeyController())
    // OAuth device grant + CLI session management (issue #558)
    try app.register(collection: OAuthController())
    try app.register(collection: APIDocumentationController())
    try app.register(collection: AgentWebSocketController())

    // Hierarchical IAM controllers
    // Projects themselves are served by generated handlers — see
    // `registerGeneratedAPIHandlers` below.
    try app.register(collection: OrganizationalUnitController())
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

    // Floating IPs: external address pools + VM NIC attachments (issue #344)
    try app.register(collection: FloatingIPController())

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

    // Workload principals (issue #491): service accounts and the workload
    // registry mapping SPIFFE IDs to principals.
    try app.register(collection: ServiceAccountController())
    try app.register(collection: WorkloadRegistrationController())

    // OpenAPI Vapor transport (spec-first, issue #583): surfaces whose handlers
    // are generated from Sources/App/openapi.yaml. Registered last so a
    // hand-written controller can never shadow a generated route unnoticed —
    // the drift suite asserts each generated route is registered exactly once.
    try registerGeneratedAPIHandlers(on: app)

    // The frontend is served by the separate Next.js container; ingress owns
    // user-facing page routing.
}
