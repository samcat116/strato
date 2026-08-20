import ControlPlanePostgres
import Vapor

/// Vapor owns the event-loop group; this handler closes the native pool before
/// Vapor tears that group down. It is registered before the background-task
/// lifecycle so Vapor's reverse shutdown order drains application work first.
struct NativePostgresLifecycleHandler: LifecycleHandler {
    let database: ControlPlanePostgres.PostgresDatabase

    func shutdownAsync(_ application: Application) async {
        await database.shutdown()
    }
}

extension Application {
    private struct NativePostgresConfigurationOverrideKey: StorageKey {
        typealias Value = ControlPlanePostgres.PostgresDatabase.Configuration
    }

    private struct StoragePoolsPersistenceKey: StorageKey {
        typealias Value = StoragePoolsPersistence
    }

    private struct OAuthDeviceSessionsPersistenceKey: StorageKey {
        typealias Value = OAuthDeviceSessionsPersistence
    }

    private struct APIKeysPersistenceKey: StorageKey {
        typealias Value = APIKeysPersistence
    }

    private struct UserDirectoryPersistenceKey: StorageKey {
        typealias Value = UserDirectoryPersistence
    }

    private struct SCIMTokensPersistenceKey: StorageKey {
        typealias Value = SCIMTokensPersistence
    }

    private struct SSFStreamsPersistenceKey: StorageKey {
        typealias Value = SSFStreamsPersistence
    }

    private struct PasskeysPersistenceKey: StorageKey {
        typealias Value = PasskeysPersistence
    }

    private struct AccountRecoveryPersistenceKey: StorageKey {
        typealias Value = AccountRecoveryPersistence
    }

    private struct AgentEnrollmentsPersistenceKey: StorageKey {
        typealias Value = AgentEnrollmentsPersistence
    }

    private struct OIDCProvidersPersistenceKey: StorageKey {
        typealias Value = OIDCProvidersPersistence
    }

    private struct SCIMExternalIDsPersistenceKey: StorageKey {
        typealias Value = SCIMExternalIDsPersistence
    }

    private struct GroupsPersistenceKey: StorageKey {
        typealias Value = GroupsPersistence
    }

    private struct HierarchyPersistenceKey: StorageKey {
        typealias Value = HierarchyPersistence
    }

    private struct IAMPersistenceKey: StorageKey {
        typealias Value = IAMPersistence
    }

    private struct ProjectsPersistenceKey: StorageKey {
        typealias Value = ProjectsPersistence
    }

    private struct NetworksPersistenceKey: StorageKey {
        typealias Value = NetworksPersistence
    }

    private struct SitesPersistenceKey: StorageKey {
        typealias Value = SitesPersistence
    }

    private struct FloatingIPPoolsPersistenceKey: StorageKey {
        typealias Value = FloatingIPPoolsPersistence
    }

    private struct ResourceQuotasPersistenceKey: StorageKey {
        typealias Value = ResourceQuotasPersistence
    }

    private struct RegistryPullSecretsPersistenceKey: StorageKey {
        typealias Value = RegistryPullSecretsPersistence
    }

    private struct VMCommandExecutionsPersistenceKey: StorageKey {
        typealias Value = VMCommandExecutionsPersistence
    }

    private struct WebhookSubscriptionsPersistenceKey: StorageKey {
        typealias Value = WebhookSubscriptionsPersistence
    }

    private struct WebhookDeliveriesPersistenceKey: StorageKey {
        typealias Value = WebhookDeliveriesPersistence
    }

    private struct WorkloadsPersistenceKey: StorageKey {
        typealias Value = WorkloadsPersistence
    }

    var storagePoolsPersistence: StoragePoolsPersistence {
        get {
            guard let persistence = storage[StoragePoolsPersistenceKey.self] else {
                preconditionFailure("Storage-pool persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(StoragePoolsPersistenceKey.self, to: newValue) }
    }

    /// Direct-handler and middleware test construction only. Production code
    /// receives this module through initializers.
    package var userDirectoryPersistence: UserDirectoryPersistence {
        get {
            guard let persistence = storage[UserDirectoryPersistenceKey.self] else {
                preconditionFailure("User-directory persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(UserDirectoryPersistenceKey.self, to: newValue) }
    }

    /// Test-construction access. Production workers receive this module when
    /// their service is assembled during boot.
    package var workloadsPersistence: WorkloadsPersistence {
        get {
            guard let persistence = storage[WorkloadsPersistenceKey.self] else {
                preconditionFailure("Workload persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(WorkloadsPersistenceKey.self, to: newValue) }
    }

    var oauthDeviceSessionsPersistence: OAuthDeviceSessionsPersistence {
        get {
            guard let persistence = storage[OAuthDeviceSessionsPersistenceKey.self] else {
                preconditionFailure("OAuth device-session persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(OAuthDeviceSessionsPersistenceKey.self, to: newValue) }
    }

    var apiKeysPersistence: APIKeysPersistence {
        get {
            guard let persistence = storage[APIKeysPersistenceKey.self] else {
                preconditionFailure("API-key persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(APIKeysPersistenceKey.self, to: newValue) }
    }

    var scimTokensPersistence: SCIMTokensPersistence {
        get {
            guard let persistence = storage[SCIMTokensPersistenceKey.self] else {
                preconditionFailure("SCIM-token persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(SCIMTokensPersistenceKey.self, to: newValue) }
    }

    var ssfStreamsPersistence: SSFStreamsPersistence {
        get {
            guard let persistence = storage[SSFStreamsPersistenceKey.self] else {
                preconditionFailure("SSF-stream persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(SSFStreamsPersistenceKey.self, to: newValue) }
    }

    var passkeysPersistence: PasskeysPersistence {
        get {
            guard let persistence = storage[PasskeysPersistenceKey.self] else {
                preconditionFailure("Passkey persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(PasskeysPersistenceKey.self, to: newValue) }
    }

    var accountRecoveryPersistence: AccountRecoveryPersistence {
        get {
            guard let persistence = storage[AccountRecoveryPersistenceKey.self] else {
                preconditionFailure("Account-recovery persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(AccountRecoveryPersistenceKey.self, to: newValue) }
    }

    /// Test-construction seam for invoking one controller method directly.
    /// Production routes and services receive this module by initializer.
    package var agentEnrollmentsPersistence: AgentEnrollmentsPersistence {
        get {
            guard let persistence = storage[AgentEnrollmentsPersistenceKey.self] else {
                preconditionFailure("Agent-enrollment persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(AgentEnrollmentsPersistenceKey.self, to: newValue) }
    }

    /// Test-construction seam. Production OIDC paths receive this module by initializer.
    package var oidcProvidersPersistence: OIDCProvidersPersistence {
        get {
            guard let persistence = storage[OIDCProvidersPersistenceKey.self] else {
                preconditionFailure("OIDC-provider persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(OIDCProvidersPersistenceKey.self, to: newValue) }
    }

    /// Test-construction seam. Production SCIM paths receive this module by initializer.
    package var scimExternalIDsPersistence: SCIMExternalIDsPersistence {
        get {
            guard let persistence = storage[SCIMExternalIDsPersistenceKey.self] else {
                preconditionFailure("SCIM external-ID persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(SCIMExternalIDsPersistenceKey.self, to: newValue) }
    }

    /// Test-construction seam. Production group paths receive this module by initializer.
    package var groupsPersistence: GroupsPersistence {
        get {
            guard let persistence = storage[GroupsPersistenceKey.self] else {
                preconditionFailure("Group persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(GroupsPersistenceKey.self, to: newValue) }
    }

    /// Test-construction seam. Production hierarchy paths receive this module by initializer.
    package var hierarchyPersistence: HierarchyPersistence {
        get {
            guard let persistence = storage[HierarchyPersistenceKey.self] else {
                preconditionFailure("Hierarchy persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(HierarchyPersistenceKey.self, to: newValue) }
    }

    /// Test-construction seam. Production IAM paths receive this module by initializer.
    package var iamPersistence: IAMPersistence {
        get {
            guard let persistence = storage[IAMPersistenceKey.self] else {
                preconditionFailure("IAM persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(IAMPersistenceKey.self, to: newValue) }
    }

    /// Construction-only test input. The runtime itself is never published in
    /// Application storage; migrated code receives concrete modules directly.
    package var nativePostgresConfigurationOverride: ControlPlanePostgres.PostgresDatabase.Configuration?
    {
        get { storage[NativePostgresConfigurationOverrideKey.self] }
        set { storage[NativePostgresConfigurationOverrideKey.self] = newValue }
    }

    /// Direct-handler test construction only. Production routes receive this
    /// module by initializer and never retrieve it from application storage.
    package var projectsPersistence: ProjectsPersistence {
        get {
            guard let persistence = storage[ProjectsPersistenceKey.self] else {
                preconditionFailure("Project persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(ProjectsPersistenceKey.self, to: newValue) }
    }

    /// Direct-handler test construction only. Production routes receive this
    /// module by initializer and never retrieve it from application storage.
    package var networksPersistence: NetworksPersistence {
        get {
            guard let persistence = storage[NetworksPersistenceKey.self] else {
                preconditionFailure("Network persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(NetworksPersistenceKey.self, to: newValue) }
    }

    /// Direct-handler test construction only.
    package var sitesPersistence: SitesPersistence {
        get {
            guard let persistence = storage[SitesPersistenceKey.self] else {
                preconditionFailure("Site persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(SitesPersistenceKey.self, to: newValue) }
    }

    /// Direct-handler test construction only.
    package var floatingIPPoolsPersistence: FloatingIPPoolsPersistence {
        get {
            guard let persistence = storage[FloatingIPPoolsPersistenceKey.self] else {
                preconditionFailure("Floating-IP pool persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(FloatingIPPoolsPersistenceKey.self, to: newValue) }
    }

    /// Direct-handler test construction only.
    package var resourceQuotasPersistence: ResourceQuotasPersistence {
        get {
            guard let persistence = storage[ResourceQuotasPersistenceKey.self] else {
                preconditionFailure("Resource-quota persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(ResourceQuotasPersistenceKey.self, to: newValue) }
    }

    /// Background desired-state assembly and direct-handler tests use the same
    /// concrete module that production routes receive at boot.
    package var registryPullSecretsPersistence: RegistryPullSecretsPersistence {
        get {
            guard let persistence = storage[RegistryPullSecretsPersistenceKey.self] else {
                preconditionFailure("Registry pull-secret persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(RegistryPullSecretsPersistenceKey.self, to: newValue) }
    }

    package var vmCommandExecutionsPersistence: VMCommandExecutionsPersistence {
        get {
            guard let persistence = storage[VMCommandExecutionsPersistenceKey.self] else {
                preconditionFailure("VM command persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(VMCommandExecutionsPersistenceKey.self, to: newValue) }
    }

    package var webhookSubscriptionsPersistence: WebhookSubscriptionsPersistence {
        get {
            guard let persistence = storage[WebhookSubscriptionsPersistenceKey.self] else {
                preconditionFailure("Webhook subscription persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(WebhookSubscriptionsPersistenceKey.self, to: newValue) }
    }

    package var webhookDeliveriesPersistence: WebhookDeliveriesPersistence {
        get {
            guard let persistence = storage[WebhookDeliveriesPersistenceKey.self] else {
                preconditionFailure("Webhook delivery persistence has not been configured")
            }
            return persistence
        }
        set { setStorageValue(WebhookDeliveriesPersistenceKey.self, to: newValue) }
    }
}
