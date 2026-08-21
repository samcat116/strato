import ControlPlanePostgres
import Vapor

func routes(_ app: Application, persistence: ControlPlanePersistence) throws {
    // Register controllers
    try app.register(collection: HealthController(database: persistence.database))
    try app.register(
        collection: UserController(
            iam: persistence.iam,
            users: persistence.userDirectory,
            hierarchy: persistence.hierarchy,
            appSettings: persistence.appSettings,
            passkeys: persistence.passkeys,
            accountClaims: persistence.accountClaims,
            oidcProviders: persistence.oidcProviders
        ))
    // Self-service passkey management for the signed-in user
    try app.register(collection: PasskeyController(passkeys: persistence.passkeys))
    try app.register(
        collection: VMController(
            workloads: persistence.workloads,
            hierarchy: persistence.hierarchy,
            storagePools: persistence.storagePools,
            vmCommands: persistence.vmCommandExecutions,
            database: persistence.storeContext))
    // Sandboxes: OCI-image Firecracker microVMs (issue #413)
    try app.register(collection: SandboxController(
        workloads: persistence.workloads,
        hierarchy: persistence.hierarchy,
        database: persistence.storeContext))
    try app.register(
        collection: OperationController(
            vmCommands: persistence.vmCommandExecutions,
            database: persistence.storeContext))
    try app.register(
        collection: OrganizationController(
            groups: persistence.groups,
            hierarchy: persistence.hierarchy,
            iam: persistence.iam,
            projects: persistence.projects,
            users: persistence.userDirectory,
            database: persistence.storeContext
        )
    )
    try app.register(collection: AuthorizationController(
        iam: persistence.iam,
        groups: persistence.groups,
        hierarchy: persistence.hierarchy,
        users: persistence.userDirectory,
        serviceAccounts: persistence.serviceAccounts,
        workloads: persistence.workloads))
    // IAM tier-2 guardrails + policy-set versioning (issue #479)
    try app.register(
        collection: GuardrailController(
            iam: persistence.iam,
            groups: persistence.groups,
            hierarchy: persistence.hierarchy,
            projects: persistence.projects,
            users: persistence.userDirectory
        )
    )
    // IAM role definitions + the action catalog (issue #605)
    try app.register(collection: RoleController(iam: persistence.iam))
    // IAM authored Cedar policies (issue #606)
    try app.register(collection: PolicyController(iam: persistence.iam))
    // IAM authorization decision logs (issue #481)
    try app.register(collection: IAMDecisionLogController(decisionLogs: persistence.decisionLogs))
    try app.register(collection: APIKeyController(apiKeys: persistence.apiKeys, iam: persistence.iam))
    // OAuth device grant + CLI session management (issue #558)
    try app.register(
        collection: OAuthController(
            oauth: persistence.oauthDeviceSessions,
            iam: persistence.iam))
    try app.register(collection: APIDocumentationController())
    try app.register(collection: AgentWebSocketController(workloads: persistence.workloads))
    try app.register(collection: AgentDesiredStateController(
        agents: persistence.agents, workloads: persistence.workloads))
    try app.register(
        collection: AgentGuestIdentityController(
            hierarchy: persistence.hierarchy,
            trustDomains: persistence.orgTrustDomains,
            workloads: persistence.workloads,
            database: persistence.storeContext))

    // Hierarchical IAM controllers
    // Projects themselves are served by generated handlers — see
    // `registerGeneratedAPIHandlers` below.
    try app.register(collection: OrganizationalUnitController(hierarchy: persistence.hierarchy))
    try app.register(
        collection: OrganizationalUnitMemberController(
            groups: persistence.groups,
            hierarchy: persistence.hierarchy,
            iam: persistence.iam,
            projects: persistence.projects,
            users: persistence.userDirectory
        )
    )
    try app.register(
        collection: ProjectMemberController(
            groups: persistence.groups,
            hierarchy: persistence.hierarchy,
            iam: persistence.iam,
            projects: persistence.projects,
            users: persistence.userDirectory,
            workloads: persistence.workloads
        )
    )
    // Registry pull secrets for private sandbox images (issue #414)
    try app.register(
        collection: RegistryPullSecretController(
            secrets: persistence.registryPullSecrets,
            projects: persistence.projects
        )
    )
    try app.register(
        collection: ResourceQuotaController(
            quotas: persistence.resourceQuotas,
            hierarchy: persistence.hierarchy,
            iam: persistence.iam,
            projects: persistence.projects
        )
    )
    try app.register(collection: HierarchyController(database: persistence.storeContext))

    // Groups controller
    try app.register(collection: GroupController(groups: persistence.groups))

    // OIDC controller
    try app.register(
        collection: OIDCController(
            providers: persistence.oidcProviders,
            groups: persistence.groups,
            externalIDs: persistence.scimExternalIDs,
            hierarchy: persistence.hierarchy,
            users: persistence.userDirectory,
            iam: persistence.iam
        )
    )
    // Agent management controller
    try app.register(
        collection: AgentController(
            enrollments: persistence.agentEnrollments,
            agents: persistence.agents,
            workloads: persistence.workloads,
            hierarchy: persistence.hierarchy,
            sites: persistence.sites,
            trustDomains: persistence.orgTrustDomains
        )
    )
    // Sites (availability zones) grouping agents into shared OVN deployments
    try app.register(
        collection: SiteController(
            sites: persistence.sites,
            agents: persistence.agents,
            hierarchy: persistence.hierarchy
        )
    )
    // Agent-reported physical disks and operator OSD eligibility.
    try app.register(
        collection: StorageDeviceController(
            storageDevices: persistence.storageDevices,
            agents: persistence.agents,
            sites: persistence.sites,
            hierarchy: persistence.hierarchy
        )
    )

    // SCIM controllers
    try app.register(
        collection: SCIMController(
            scimTokens: persistence.scimTokens,
            externalIDs: persistence.scimExternalIDs,
            groups: persistence.groups,
            hierarchy: persistence.hierarchy,
            users: persistence.userDirectory
        )
    )
    try app.register(collection: SCIMTokenController(scimTokens: persistence.scimTokens))

    // Shared Signals Framework receiver (issue #38)
    try app.register(collection: SSFStreamController(streams: persistence.ssfStreams))

    // User-managed webhook notifications (issue #559)
    try app.register(
        collection: WebhookSubscriptionController(
            subscriptions: persistence.webhookSubscriptions,
            deliveries: persistence.webhookDeliveries,
            projects: persistence.projects))

    // Image management controller
    try app.register(collection: ImageController(
        workloads: persistence.workloads, database: persistence.storeContext))

    // Volume management controller
    try app.register(
        collection: VolumeController(
            storagePools: persistence.storagePools,
            iam: persistence.iam,
            projects: persistence.projects,
            database: persistence.storeContext
        )
    )

    // Network management controller
    try app.register(
        collection: NetworkController(
            iam: persistence.iam,
            projects: persistence.projects,
            networks: persistence.networks,
            sites: persistence.sites,
            hierarchy: persistence.hierarchy,
            database: persistence.storeContext
        )
    )

    // Floating IPs: external address pools + VM NIC attachments (issue #344)
    try app.register(
        collection: FloatingIPController(
            allocations: persistence.floatingIPAllocations,
            iam: persistence.iam,
            projects: persistence.projects,
            pools: persistence.floatingIPPools,
            sites: persistence.sites,
            database: persistence.storeContext
        )
    )
    try app.register(collection: LoadBalancerController(
        iam: persistence.iam,
        projects: persistence.projects,
        database: persistence.storeContext))
    try app.register(collection: SecurityGroupController(
        iam: persistence.iam,
        projects: persistence.projects,
        database: persistence.storeContext))

    // DNS zones, records, and zone↔network attachments (issue #770). Model
    // only — nothing realizes these yet.
    try app.register(collection: DNSController(
        iam: persistence.iam,
        projects: persistence.projects,
        database: persistence.storeContext))

    // Console WebSocket controller for VM console streaming
    try app.register(collection: ConsoleWebSocketController(database: persistence.storeContext))

    // VM graphics console: mint + attach for the VNC relay (issue #566)
    try app.register(collection: VNCWebSocketController(database: persistence.storeContext))

    // VM and sandbox guest-exec attach WebSockets (STR-81)
    try app.register(collection: GuestExecWebSocketController())

    // VM Logs controller for querying logs from Loki
    try app.register(collection: LogsController(database: persistence.storeContext))

    // Audit trail query API (issue #39)
    try app.register(collection: AuditEventController(auditEvents: persistence.auditEvents))

    // Workload Identity (SPIFFE / SPIRE) read API
    try app.register(collection: WorkloadIdentityController())

    // Workload principals (issue #491): service accounts and the workload
    // registry mapping SPIFFE IDs to principals.
    try app.register(collection: ServiceAccountController(
        serviceAccounts: persistence.serviceAccounts,
        workloads: persistence.workloads,
        projects: persistence.projects,
        iam: persistence.iam,
        groups: persistence.groups,
        hierarchy: persistence.hierarchy,
        users: persistence.userDirectory))
    try app.register(collection: WorkloadRegistrationController(
        workloads: persistence.workloads,
        hierarchy: persistence.hierarchy,
        projects: persistence.projects,
        iam: persistence.iam,
        groups: persistence.groups,
        users: persistence.userDirectory))

    // OpenAPI Vapor transport (spec-first, issue #583): surfaces whose handlers
    // are generated from Sources/App/openapi.yaml. Registered last so a
    // hand-written controller can never shadow a generated route unnoticed —
    // the drift suite asserts each generated route is registered exactly once.
    try registerGeneratedAPIHandlers(on: app, persistence: persistence)

    // The frontend is served by the separate Next.js container; ingress owns
    // user-facing page routing.
}
