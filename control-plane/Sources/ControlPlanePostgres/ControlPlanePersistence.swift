/// Immutable root for Strato's concrete persistence modules.
///
/// Modules are added cohort-by-cohort. Keeping construction centralized lets
/// Vapor inject only the capability each controller or worker needs.
public struct ControlPlanePersistence: Sendable {
    public let database: PostgresDatabase
    public let storeContext: PostgresStoreContext
    public let appSettings: AppSettingsPersistence
    public let auditEvents: AuditEventsPersistence
    public let decisionLogs: DecisionLogsPersistence
    public let storageDevices: StorageDevicesPersistence
    public let storagePools: StoragePoolsPersistence
    public let floatingIPAllocations: FloatingIPAllocationsPersistence
    public let oauthDeviceSessions: OAuthDeviceSessionsPersistence
    public let apiKeys: APIKeysPersistence
    public let scimTokens: SCIMTokensPersistence
    public let ssfStreams: SSFStreamsPersistence
    public let userSecurity: UserSecurityPersistence
    public let userDirectory: UserDirectoryPersistence
    public let passkeys: PasskeysPersistence
    public let accountClaims: AccountClaimsPersistence
    public let accountRecovery: AccountRecoveryPersistence
    public let bootstrap: BootstrapPersistence
    public let agentEnrollments: AgentEnrollmentsPersistence
    public let agents: AgentsPersistence
    public let oidcProviders: OIDCProvidersPersistence
    public let orgTrustDomains: OrgTrustDomainsPersistence
    public let scimExternalIDs: SCIMExternalIDsPersistence
    public let groups: GroupsPersistence
    public let iam: IAMPersistence
    public let hierarchy: HierarchyPersistence
    public let projects: ProjectsPersistence
    public let workloads: WorkloadsPersistence
    public let serviceAccounts: ServiceAccountsPersistence
    public let resourceQuotas: ResourceQuotasPersistence
    public let sites: SitesPersistence
    public let networks: NetworksPersistence
    public let floatingIPPools: FloatingIPPoolsPersistence
    public let registryPullSecrets: RegistryPullSecretsPersistence
    public let vmCommandExecutions: VMCommandExecutionsPersistence
    public let webhookSubscriptions: WebhookSubscriptionsPersistence
    public let webhookDeliveries: WebhookDeliveriesPersistence

    public init(database: PostgresDatabase) {
        self.database = database
        self.storeContext = PostgresStoreContext(database: database)
        self.appSettings = AppSettingsPersistence(database: database)
        self.auditEvents = AuditEventsPersistence(database: database)
        self.decisionLogs = DecisionLogsPersistence(database: database)
        self.storageDevices = StorageDevicesPersistence(database: database)
        self.storagePools = StoragePoolsPersistence(database: database)
        self.floatingIPAllocations = FloatingIPAllocationsPersistence(database: database)
        self.oauthDeviceSessions = OAuthDeviceSessionsPersistence(database: database)
        self.apiKeys = APIKeysPersistence(database: database)
        self.scimTokens = SCIMTokensPersistence(database: database)
        self.ssfStreams = SSFStreamsPersistence(database: database)
        self.userSecurity = UserSecurityPersistence(database: database)
        self.userDirectory = UserDirectoryPersistence(database: database)
        self.passkeys = PasskeysPersistence(database: database)
        self.accountClaims = AccountClaimsPersistence(database: database)
        self.accountRecovery = AccountRecoveryPersistence(database: database)
        self.bootstrap = BootstrapPersistence(database: database)
        self.agentEnrollments = AgentEnrollmentsPersistence(database: database)
        self.agents = AgentsPersistence(database: database)
        self.oidcProviders = OIDCProvidersPersistence(database: database)
        self.orgTrustDomains = OrgTrustDomainsPersistence(database: database)
        self.scimExternalIDs = SCIMExternalIDsPersistence(database: database)
        self.groups = GroupsPersistence(database: database)
        self.iam = IAMPersistence(database: database)
        self.hierarchy = HierarchyPersistence(database: database)
        self.projects = ProjectsPersistence(database: database)
        self.workloads = WorkloadsPersistence(database: database)
        self.serviceAccounts = ServiceAccountsPersistence(database: database)
        self.resourceQuotas = ResourceQuotasPersistence(database: database)
        self.sites = SitesPersistence(database: database)
        self.networks = NetworksPersistence(database: database)
        self.floatingIPPools = FloatingIPPoolsPersistence(database: database)
        self.registryPullSecrets = RegistryPullSecretsPersistence(database: database)
        self.vmCommandExecutions = VMCommandExecutionsPersistence(database: database)
        self.webhookSubscriptions = WebhookSubscriptionsPersistence(database: database)
        self.webhookDeliveries = WebhookDeliveriesPersistence(database: database)
    }
}
